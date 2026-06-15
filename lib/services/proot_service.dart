import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;

  String? _prootPath;
  String? _rootfsPath;

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  Future<bool> checkEnvironment() async {
    try {
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      if (await Directory(rootfs).exists()) {
        final sh = File('$rootfs/bin/sh');
        if (await sh.exists() && await sh.length() > 0) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Linux no instalado – pulsa Setup';
      notifyListeners();
      return false;
    } catch (e) {
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
    notifyListeners();

    try {
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
      _rootfsPath = rootfs;

      await Directory(appDir).create(recursive: true);
      await Directory(rootfs).create(recursive: true);

      // ── 1. Descargar Alpine minirootfs ──
      _downloadProgress = 0.05;
      _statusMessage = 'Descargando Alpine Linux…';
      notifyListeners();

      final tgzPath = '$appDir/rootfs.tar.gz';
      if (!await File(tgzPath).exists()) {
        await _downloadFile(
          'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz',
          tgzPath, 0.05, 0.50,
        );
      }

      // ── 2. Extraer rootfs ──
      _downloadProgress = 0.50;
      _statusMessage = 'Extrayendo rootfs…';
      notifyListeners();

      if (!await File('$rootfs/bin/sh').exists() ||
           await File('$rootfs/bin/sh').length() == 0) {
        await _extractRootfs(tgzPath, rootfs);
      }

      // ── 3. Verificar /bin/sh y reparar hardlinks si necesario ──
      _downloadProgress = 0.75;
      _statusMessage = 'Verificando…';
      notifyListeners();

      final shOk = await File('$rootfs/bin/sh').exists() &&
                   await File('$rootfs/bin/sh').length() > 0;

      if (!shOk) {
        _statusMessage = 'Reparando hardlinks…';
        notifyListeners();
        await _fixHardlinks(rootfs);
      }

      // ── 4. Configurar red ──
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // ── 5. Hacer ejecutables binarios ──
      await _chmodKeyBins(rootfs);

      // ── 6. PROOT ──
      _downloadProgress = 0.85;
      _statusMessage = 'Descargando PROOT…';
      notifyListeners();

      final prootPath = '$appDir/proot';
      if (!await File(prootPath).exists()) {
        try {
          await _downloadFile(
            'https://github.com/proot-me/proot/releases/download/v5.4.0/proot-v5.4.0-aarch64-static',
            prootPath, 0.85, 0.95,
          );
          await Process.run('chmod', ['755', prootPath]);
        } catch (e) {
          _lastOutput += 'PROOT no disponible: $e\n';
        }
      }
      if (await File(prootPath).exists()) _prootPath = prootPath;

      // ── Verificación final ──
      final shFinal = await File('$rootfs/bin/sh').exists() &&
                      await File('$rootfs/bin/sh').length() > 0;

      _downloadProgress = 1.0;
      _initialized = shFinal;
      _statusMessage = shFinal
          ? 'Alpine Linux listo'
          : 'Error: /bin/sh no encontrado en rootfs';
      _lastOutput += '\n$_statusMessage';
    } catch (e) {
      _statusMessage = 'Error: $e';
      _lastOutput += '\nError: $e';
      _initialized = false;
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  // ─── Extraer rootfs (toybox → Dart + post-procesado hardlinks) ───
  Future<void> _extractRootfs(String tgzPath, String rootfs) async {
    // MÉTODO 1: toybox/toolbox tar del sistema (maneja hardlinks)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          _lastOutput += 'Intentando extraer con $tb\n';
          await Process.run(
            tb, ['tar', '-xf', tgzPath, '-C', rootfs],
          ).timeout(const Duration(seconds: 120));

          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) {
            _lastOutput += 'Extraído con $tb (hardlinks OK)\n';
            return;
          }
        } catch (e) {
          _lastOutput += '$tb falló: $e\n';
        }
      }
    }

    // MÉTODO 2: Extracción Dart completa (hardlinks = 0 bytes)
    _lastOutput += 'Usando extracción Dart\n';
    await _extractAllDart(tgzPath, rootfs);
  }

  // ─── Extracción completa con Dart ───
  Future<void> _extractAllDart(String tarPath, String destPath) async {
    final bytes = await File(tarPath).readAsBytes();
    final gz = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gz);

    int count = 0;
    final total = archive.length;

    for (final entry in archive) {
      String name = entry.name;
      if (name.startsWith('./')) name = name.substring(2);
      if (name.isEmpty || name == '.') continue;

      final outPath = '$destPath/$name';

      // Directorio
      if (name.endsWith('/')) {
        await Directory(outPath).create(recursive: true);
        count++;
        if (count % 200 == 0) _pulse(count, total);
        continue;
      }

      await Directory(outPath).parent.create(recursive: true);

      // Symlink → copiar archivo destino
      if (entry.isSymbolicLink) {
        final target = entry.symbolicLink ?? '';
        if (target.isNotEmpty) {
          final resolved = target.startsWith('/')
              ? '$destPath$target'
              : '${Directory(outPath).parent.path}/$target';
          if (await File(resolved).exists()) {
            try { await File(resolved).copy(outPath); } catch (_) {}
          }
        }
        count++;
        if (count % 200 == 0) _pulse(count, total);
        continue;
      }

      // Archivo normal
      if (entry.isFile) {
        final data = entry.content;
        if (data.isNotEmpty) {
          await File(outPath).writeAsBytes(data);
        } else {
          // Hardlink (0 bytes) → crear vacío, se reparará después
          await File(outPath).writeAsString('');
        }
        count++;
        if (count % 200 == 0) _pulse(count, total);
        continue;
      }

      count++;
    }

    _lastOutput += 'Extraídos $count archivos\n';
  }

  void _pulse(int count, int total) {
    if (total > 0) {
      _downloadProgress = 0.50 + (count / total) * 0.25;
      _statusMessage = 'Extrayendo ${(count * 100 / total).toInt()}%';
      notifyListeners();
    }
  }

  // ─── Reparar hardlinks: copiar busybox a archivos de 0 bytes ───
  Future<void> _fixHardlinks(String rootfs) async {
    // Buscar busybox (es un archivo real, no hardlink)
    final bbFile = File('$rootfs/bin/busybox');
    List<int>? bbData;
    if (await bbFile.exists()) {
      final len = await bbFile.length();
      if (len > 0) {
        bbData = await bbFile.readAsBytes();
      }
    }

    if (bbData == null || bbData.isEmpty) {
      _lastOutput += 'Error: busybox no encontrado o vacío\n';
      return;
    }

    // Buscar todos los archivos de 0 bytes en bin/, sbin/, usr/bin/, usr/sbin/
    int fixed = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;

      await for (final entity in d.list(followLinks: false)) {
        if (entity is File) {
          try {
            final len = await entity.length();
            if (len == 0) {
              // Es un hardlink a busybox → copiar contenido
              await entity.writeAsBytes(bbData!);
              fixed++;
            }
          } catch (_) {}
        }
      }
    }

    _lastOutput += 'Hardlinks reparados: $fixed\n';
  }

  // ─── Hacer ejecutables ───
  Future<void> _chmodKeyBins(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (await d.exists()) {
        try {
          await for (final entity in d.list()) {
            if (entity is File) {
              try { await Process.run('chmod', ['755', entity.path]); } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }
  }

  // ─── Ejecutar comandos ───
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\nPulsa "Setup Linux" primero.\n';
    }

    final rootfs = _rootfsPath!;
    final proot = _prootPath;
    final linker = (await File('/system/bin/linker64').exists())
        ? '/system/bin/linker64'
        : (await File('/system/bin/linker').exists())
            ? '/system/bin/linker'
            : null;

    final bbPath = '$rootfs/bin/busybox';
    final hasBb = await File(bbPath).exists() && await File(bbPath).length() > 0;
    final shPath = '$rootfs/bin/sh';
    final hasSh = await File(shPath).exists() && await File(shPath).length() > 0;

    try {
      // 1: PROOT
      if (proot != null && await File(proot).exists() && linker != null) {
        try {
          final args = [
            '-0', '-r', rootfs,
            '-b', '/proc', '-b', '/sys', '-b', '/dev', '-b', '/system',
            '-w', '/root',
            '/usr/bin/env',
            'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME=/root', 'TERM=xterm-256color',
            'sh', '-c', command,
          ];
          final result = await Process.run(
            linker, [proot, ...args],
            workingDirectory: rootfs,
            environment: { 'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib' },
          ).timeout(timeout);
          _lastOutput = (result.stderr as String).isNotEmpty
              ? '${result.stdout}\n${result.stderr}' : result.stdout as String;
          return _lastOutput;
        } catch (e) { _lastOutput = 'PROOT falló: $e\n'; }
      }

      // 2: Linker + busybox sh
      if (linker != null && hasBb) {
        try {
          final result = await Process.run(
            linker, [bbPath, 'sh', '-c', command],
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
        } catch (e) { _lastOutput = 'Linker+bb falló: $e\n'; }
      }

      // 3: Linker + sh directo
      if (linker != null && hasSh) {
        try {
          final result = await Process.run(
            linker, [shPath, '-c', command],
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
        } catch (e) { _lastOutput = 'Linker+sh falló: $e\n'; }
      }

      // 4: /system/bin/sh + PATH rootfs
      if (await File('/system/bin/sh').exists()) {
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
      }

      return 'Error: No se pudo ejecutar el comando.\n';
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
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} en $url');
      }
      final total = response.contentLength;
      int recv = 0;
      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        recv += chunk.length;
        if (total > 0) {
          _downloadProgress = sw + (recv / total) * (ew - sw);
          if (recv % (1024 * 512) < chunk.length) notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
    } finally { client.close(); }
  }

  Future<void> resetEnvironment() async {
    final appDir = await _appDir;
    try { await Directory(appDir).delete(recursive: true); } catch (_) {}
    _initialized = false;
    _prootPath = null;
    _rootfsPath = null;
    _statusMessage = 'Entorno reiniciado';
    notifyListeners();
  }
}
