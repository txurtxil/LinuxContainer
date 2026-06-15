import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier {
  static final ProotService _instance = ProotService._internal();
  factory ProotService() => _instance;
  ProotService._internal();

  bool _initialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusMessage = 'No iniciado';
  String _lastOutput = '';

  final List<String> _log = [];
  List<String> get log => List.unmodifiable(_log);
  String get logText => _log.join('\n');
  void _logMsg(String msg) {
    _log.add('[${DateTime.now().toString().substring(11, 19)}] $msg');
    debugPrint('ProotSetup: $msg');
  }

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;

  String? _rootfsPath;

  static const String _minirootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz';
  static const String _debianRootfsUrl =
      'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.tar.xz';
  static const String _prootRsUrl =
      'https://github.com/proot-me/proot-rs/releases/download/v0.1.0/proot-rs-aarch64';

  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  Future<bool> checkEnvironment() async {
    _log.clear();
    try {
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      _logMsg('Comprobando rootfs en: $rootfs');
      if (await Directory(rootfs).exists()) {
        final sh = File('$rootfs/bin/sh');
        if (await sh.exists()) {
          final st = await sh.stat();
          if (st.size > 0) {
            _initialized = true;
            _statusMessage = 'Linux listo';
            _logMsg('Rootfs OK, /bin/sh existe (${st.size} bytes)');
            notifyListeners();
            return true;
          }
        }
      }
      _statusMessage = 'Linux no instalado – pulsa Setup';
      notifyListeners();
      return false;
    } catch (e) {
      _logMsg('Error checkEnvironment: $e');
      _statusMessage = 'Error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> setupEnvironment() async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _statusMessage = 'Iniciando…';
    _lastOutput = '';
    _log.clear();
    _logMsg('=== INICIO SETUP ===');
    notifyListeners();

    try {
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
      _rootfsPath = rootfs;
      await Directory(appDir).create(recursive: true);
      await Directory(rootfs).create(recursive: true);

      bool ok = false;

      // 1: Asset embeebido (Alpine 3.24.1)
      ok = await _setupFromAsset(rootfs);
      if (ok) { _logMsg('✓ Rootfs extraído desde asset'); }

      // 2: Minirootfs descargado
      if (!ok) {
        ok = await _setupWithMinirootfs(appDir, rootfs);
        if (ok) { _logMsg('✓ Rootfs desde minirootfs'); }
      }

      // 3: Debian
      if (!ok) {
        ok = await _setupWithDebianRootfs(appDir, rootfs);
        if (ok) { _logMsg('✓ Rootfs Debian'); }
      }

      if (!ok) { throw Exception('No se pudo crear el rootfs'); }

      // ─── Post: reparar hardlinks (copiar busybox a archivos 0 bytes) ───
      _logMsg('Reparando hardlinks…');
      await _fixHardlinks(rootfs);

      // ─── DNS ───
      _downloadProgress = 0.80;
      _statusMessage = 'Configurando red…';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      if (await File('$rootfs/etc/apt').exists()) {
        _logMsg('Rootfs Debian, configurando apt');
        final aptDir = Directory('$rootfs/etc/apt');
        await aptDir.create(recursive: true);
        if (!await File('$rootfs/etc/apt/sources.list').exists()) {
          await File('$rootfs/etc/apt/sources.list').writeAsString(
            'deb http://deb.debian.org/debian bookworm main contrib non-free\n'
            'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free\n'
            'deb http://deb.debian.org/debian bookworm-updates main contrib non-free\n');
        }
      }

      // ─── Permisos ───
      await _chmodBins(rootfs);

      // ─── PROOT-rs ───
      _downloadProgress = 0.90;
      _statusMessage = 'Descargando PROOT-rs…';
      notifyListeners();
      await _downloadProotRs(appDir);

      // ─── Verificación ───
      bool shOk = await File('$rootfs/bin/sh').exists() &&
                  await File('$rootfs/bin/sh').length() > 0;

      _downloadProgress = 1.0;
      _initialized = shOk;
      _statusMessage = shOk
          ? 'Linux listo'
          : 'Error: /bin/sh no encontrado en rootfs';
      _logMsg(_statusMessage);
      _logMsg('=== FIN SETUP ===');
    } catch (e) {
      _logMsg('EXCEPCIÓN: $e');
      _statusMessage = 'Error: $e';
      _initialized = false;
    } finally {
      _isDownloading = false;
      _lastOutput = logText;
      notifyListeners();
    }
  }

  // ────────── Asset con archive package ──────────
  Future<bool> _setupFromAsset(String rootfs) async {
    _logMsg('--- Buscando assets embebidos ---');
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      if (!manifest.contains('assets/rootfs.tar.gz')) {
        _logMsg('No hay asset de rootfs en el APK');
        return false;
      }

      _logMsg('Leyendo asset: assets/rootfs.tar.gz');
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      final bytes = data.buffer.asUint8List();

      _logMsg('Descomprimiendo con archive package…');
      final gzBytes = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gzBytes);

      _logMsg('Extrayendo ${archive.length} entradas…');
      
      int dirs = 0, files = 0, symlinks = 0;

      for (final entry in archive) {
        String name = entry.name;
        if (name.startsWith('./')) { name = name.substring(2); }
        if (name.isEmpty || name == '.') { continue; }

        final outPath = '$rootfs/$name';

        // Directorio
        if (name.endsWith('/')) {
          await Directory(outPath).create(recursive: true);
          dirs++;
          
          _pulse(count, dirs + files + symlinks + 1);
          continue;
        }

        await Directory(outPath).parent.create(recursive: true);

        // Symlink
        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink;
          if (target != null && target.isNotEmpty) {
            final resolved = target.startsWith('/')
                ? '$rootfs$target'
                : '${Directory(outPath).parent.path}/$target';
            if (await File(resolved).exists()) {
              try { await File(resolved).copy(outPath); } catch (_) {}
            }
          }
          symlinks++;
          
          _pulse(count, archive.length);
          continue;
        }

        // Archivo normal
        if (entry.isFile) {
          final content = entry.content;
          if (content.isNotEmpty) {
            await File(outPath).writeAsBytes(content);
            files++;
          } else {
            // Hardlink (0 bytes) → se repara después
            await File(outPath).writeAsString('');
          }
          
          _pulse(count, archive.length);
          continue;
        }

        
      }

      _logMsg('Extraídos: $dirs directorios, $files archivos, $symlinks symlinks');

      // Verificar que busybox existe y tiene contenido
      final bb = File('$rootfs/bin/busybox');
      if (await bb.exists() && await bb.length() > 0) {
        _logMsg('busybox OK: ${await bb.length()} bytes');
        return true;
      }

      _logMsg('ERROR: busybox no encontrado o vacío tras extracción');
      return false;
    } catch (e) {
      _logMsg('Asset+archive falló: $e');
      _logMsg('Stack: ${StackTrace.current}');
      return false;
    }
  }

  void _pulse(int count, int total) {
    if (total > 0 && count % 100 == 0) {
      _downloadProgress = 0.50 + (count / total) * 0.30;
      _statusMessage = 'Extrayendo ${(count * 100 ~/ total)}%';
      notifyListeners();
    }
  }

  // ────────── Reparar hardlinks ──────────
  Future<void> _fixHardlinks(String rootfs) async {
    final bbFile = File('$rootfs/bin/busybox');
    if (!await bbFile.exists()) { _logMsg('busybox no existe'); return; }
    final bbLen = await bbFile.length();
    if (bbLen == 0) { _logMsg('busybox tamaño 0'); return; }

    _logMsg('busybox: $bbLen bytes, reparando hardlinks…');
    final bbData = await bbFile.readAsBytes();
    int fixed = 0;

    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) { continue; }
      try {
        await for (final entity in d.list(followLinks: false)) {
          if (entity is File) {
            try {
              if (await entity.length() == 0) {
                await entity.writeAsBytes(bbData);
                fixed++;
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    _logMsg('Hardlinks reparados: $fixed');
  }

  // ────────── Minirootfs descargado ──────────
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    _logMsg('--- Minirootfs descargado ---');
    _statusMessage = 'Descargando Alpine…';
    notifyListeners();

    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try {
        await _downloadFile(_minirootfsUrl, tgzPath, 0.20, 0.50);
      } catch (e) {
        _logMsg('ERROR descarga: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo con archive…';
    notifyListeners();
    return _extractTarDart(tgzPath, rootfs);
  }

  // ────────── Debian ──────────
  Future<bool> _setupWithDebianRootfs(String appDir, String rootfs) async {
    _logMsg('--- Debian rootfs ---');
    _statusMessage = 'Descargando Debian…';
    notifyListeners();

    final xzPath = '$appDir/debian-rootfs.tar.xz';
    if (!await File(xzPath).exists()) {
      try {
        await _downloadFile(_debianRootfsUrl, xzPath, 0.20, 0.50);
      } catch (e) {
        _logMsg('ERROR descarga: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo Debian…';
    notifyListeners();

    // Toybox para .tar.xz (Dart no maneja XZ)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          await Process.run(tb, ['tar', '-xf', xzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) { return true; }
        } catch (e) { _logMsg('$tb falló: $e'); }
      }
    }
    return false;
  }

  // ────────── Extraer tar.gz con archive package ──────────
  Future<bool> _extractTarDart(String tgzPath, String rootfs) async {
    try {
      final bytes = await File(tgzPath).readAsBytes();
      final gz = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gz);

      
      for (final entry in archive) {
        String name = entry.name;
        if (name.startsWith('./')) { name = name.substring(2); }
        if (name.isEmpty || name == '.') { continue; }

        final outPath = '$rootfs/$name';

        if (name.endsWith('/')) {
          await Directory(outPath).create(recursive: true);
          continue;
        }

        await Directory(outPath).parent.create(recursive: true);

        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink;
          if (target != null && target.isNotEmpty) {
            final resolved = target.startsWith('/')
                ? '$rootfs$target'
                : '${Directory(outPath).parent.path}/$target';
            if (await File(resolved).exists()) {
              try { await File(resolved).copy(outPath); } catch (_) {}
            }
          }
          continue;
        }

        if (entry.isFile) {
          final content = entry.content;
          if (content.isNotEmpty) {
            await File(outPath).writeAsBytes(content);
          } else {
            await File(outPath).writeAsString('');
          }
          continue;
        }
        
      }
      return true;
    } catch (e) {
      _logMsg('Error extracción Dart: $e');
      return false;
    }
  }

  // ────────── Permisos ──────────
  Future<void> _chmodBins(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (await d.exists()) {
        try {
          await for (final entity in d.list()) {
            if (entity is File) {
              try {
                await Process.run('chmod', ['755', entity.path])
                    .timeout(const Duration(seconds: 5));
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }
  }

  // ────────── PROOT-rs ──────────
  Future<void> _downloadProotRs(String appDir) async {
    final prootPath = '$appDir/proot';
    if (await File(prootPath).exists()) { return; }
    try {
      _logMsg('Descargando PROOT-rs');
      await _downloadFile(_prootRsUrl, prootPath, 0.85, 0.95);
      await Process.run('chmod', ['755', prootPath]);
      _logMsg('PROOT-rs OK');
    } catch (e) {
      _logMsg('PROOT-rs no disponible: $e');
    }
  }

  // ────────── runCommand ──────────
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\nPulsa "Setup Linux" primero.\n';
    }

    final rootfs = _rootfsPath!;
    final linker = await _linker;

    String? shellPath;
    for (final p in ['$rootfs/bin/sh', '$rootfs/bin/busybox', '$rootfs/bin/dash']) {
      if (await File(p).exists() && await File(p).length() > 0) { shellPath = p; break; }
    }

    if (shellPath == null && await File('/system/bin/sh').exists()) {
      try {
        final result = await Process.run(
          '/system/bin/sh', ['-c', command],
          environment: {
            'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                    '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                    ':/system/bin:/system/xbin',
            'HOME': '/root', 'TERM': 'xterm-256color',
            'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
          },
          workingDirectory: rootfs,
        ).timeout(timeout);
        _lastOutput = (result.stderr as String).isNotEmpty
            ? '${result.stdout}\n${result.stderr}' : result.stdout as String;
        return _lastOutput;
      } catch (e) { _lastOutput = 'system sh falló: $e\n'; }
    }

    if (shellPath == null) { return 'Error: No hay shell disponible.\n'; }

    try {
      if (linker != null) {
        final result = await Process.run(
          linker, [shellPath, '-c', command],
          environment: {
            'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                    '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                    ':/system/bin:/system/xbin',
            'HOME': '/root', 'TERM': 'xterm-256color',
            'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
          },
          workingDirectory: rootfs,
        ).timeout(timeout);
        _lastOutput = (result.stderr as String).isNotEmpty
            ? '${result.stdout}\n${result.stderr}' : result.stdout as String;
        return _lastOutput;
      }

      final result = await Process.run(
        shellPath, ['-c', command],
        workingDirectory: rootfs,
      ).timeout(timeout);
      _lastOutput = (result.stderr as String).isNotEmpty
          ? '${result.stdout}\n${result.stderr}' : result.stdout as String;
      return _lastOutput;
    } on TimeoutException {
      return '\n[Timeout] El comando excedió ${timeout.inSeconds}s\n';
    } catch (e) {
      _lastOutput = '\n[Error] $e\n';
      _statusMessage = 'Error de ejecución';
      notifyListeners();
      return _lastOutput;
    }
  }

  Future<void> _downloadFile(String url, String path, double sw, double ew) async {
    final client = HttpClient();
    try {
      _logMsg('Download: $url');
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      _logMsg('HTTP ${response.statusCode}');
      if (response.statusCode != 200) { throw Exception('HTTP ${response.statusCode}'); }
      final total = response.contentLength;
      int recv = 0;
      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        recv += chunk.length;
        if (total > 0) {
          _downloadProgress = sw + (recv / total) * (ew - sw);
          if (recv % (1024 * 512) < chunk.length) { notifyListeners(); }
        }
      }
      await sink.flush();
      await sink.close();
      _logMsg('OK: $recv bytes');
    } finally { client.close(); }
  }

  Future<void> resetEnvironment() async {
    final appDir = await _appDir;
    try { await Directory(appDir).delete(recursive: true); } catch (_) {}
    _initialized = false;
    _rootfsPath = null;
    _statusMessage = 'Entorno reiniciado';
    _log.clear();
    _logMsg('Entorno reiniciado');
    notifyListeners();
  }
}
