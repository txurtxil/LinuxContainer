import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier {
  // ─── Singleton ───
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

  // ─── Comprobación ───
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

  // ─── Setup ───
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

      // ── 2. Extraer busybox del tar.gz (con Dart) ──
      _downloadProgress = 0.50;
      _statusMessage = 'Extrayendo BusyBox…';
      notifyListeners();

      final bbPath = '$appDir/bin/busybox';
      await Directory('$appDir/bin').create(recursive: true);
      if (!await File(bbPath).exists()) {
        await _extractSingleEntry(tgzPath, 'bin/busybox', bbPath);
        await Process.run('chmod', ['755', bbPath]);
      }

      // ── 3. Usar busybox (via linker) para extraer rootfs completo ──
      if (!await File('$rootfs/bin/sh').exists() ||
          await File('$rootfs/bin/sh').length() == 0) {

        _downloadProgress = 0.55;
        _statusMessage = 'Extrayendo rootfs con BusyBox…';
        notifyListeners();

        await _extractRootfsWithBusybox(tgzPath, rootfs, bbPath);
      }

      // ── 4. Verificar y configurar ──
      _downloadProgress = 0.75;
      _statusMessage = 'Configurando…';
      notifyListeners();

      // Asegurar ejecutables
      await _chmodCritical(rootfs);

      // DNS
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // ── 5. PROOT ──
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
      final shOk = await File('$rootfs/bin/sh').exists()
                  && await File('$rootfs/bin/sh').length() > 0;

      _downloadProgress = 1.0;
      _initialized = shOk;
      _statusMessage = shOk ? 'Alpine Linux listo'
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

  // ─── Extraer un solo archivo del tar.gz ───
  Future<void> _extractSingleEntry(String tarPath, String entryName, String outPath) async {
    final bytes = await File(tarPath).readAsBytes();
    final gz = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gz);

    for (final entry in archive) {
      String name = entry.name;
      if (name.startsWith('./')) name = name.substring(2);
      if (name == entryName && entry.isFile) {
        final data = entry.content;
        if (data.isNotEmpty) {
          await File(outPath).writeAsBytes(data);
          return;
        }
      }
    }
    // Si no encontramos el entry, intentar extraer todo y luego copiar
    for (final entry in archive) {
      String name = entry.name;
      if (name.startsWith('./')) name = name.substring(2);
      if (name == entryName && entry.isFile) {
        // entry.content podría ser vacío (hardlink)
        await File(outPath).writeAsBytes(entry.content);
        return;
      }
    }
    throw Exception('No se encontró $entryName en el rootfs');
  }

  // ─── Extraer rootfs usando busybox (via linker) ───
  Future<void> _extractRootfsWithBusybox(String tgzPath, String rootfs, String bbPath) async {
    final linker = (await File('/system/bin/linker64').exists())
        ? '/system/bin/linker64'
        : (await File('/system/bin/linker').exists())
            ? '/system/bin/linker'
            : null;

    if (linker == null) {
      // Sin linker, intentar extraer con Dart completo
      _statusMessage = 'Sin linker – extrayendo con Dart…';
      notifyListeners();
      await _extractAllDart(tgzPath, rootfs);
      return;
    }

    // Intentar toybox tar del sistema primero (maneja hardlinks)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          await Process.run(
            tb, ['tar', '-xf', tgzPath, '-C', rootfs,
                 '--no-same-permissions', '--no-same-owner'],
          ).timeout(const Duration(seconds: 120));
          // Verificar que extrajo bien
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) {
            _lastOutput += 'Extraído con $tb\n';
            return;
          }
        } catch (_) {}
      }
    }

    // Usar linker64 + busybox tar (funciona porque busybox es estático
    // y linker64 carga musl desde LD_LIBRARY_PATH)
    try {
      await Process.run(
        linker, [bbPath, 'tar', '-xf', tgzPath, '-C', rootfs,
                 '--no-same-permissions', '--no-same-owner'],
        environment: {
          'PATH': '$rootfs/usr/bin:$rootfs/bin:/system/bin',
          'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
        },
      ).timeout(const Duration(seconds: 120));

      if (await File('$rootfs/bin/sh').exists() &&
          await File('$rootfs/bin/sh').length() > 0) {
        _lastOutput += 'Extraído con linker+busybox\n';
        return;
      }
    } catch (_) {}

    // Fallback: extraer todo con Dart (sin detección de hardlinks)
    _statusMessage = 'Usando extracción Dart (fallback)…';
    notifyListeners();
    await _extractAllDart(tgzPath, rootfs);
  }

  // ─── Extracción con Dart (hardlinks quedan como archivos vacíos) ───
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

      if (name.endsWith('/')) {
        await Directory(outPath).create(recursive: true);
        count++;
        if (count % 100 == 0) _pulseExtract(count, total);
        continue;
      }

      await Directory(outPath).parent.create(recursive: true);

      if (entry.isSymbolicLink) {
        final target = entry.symbolicLink ?? '';
        if (target.isNotEmpty) {
          final resolved = target.startsWith('/')
              ? '$destPath$target'
              : '${Directory(outPath).parent.path}/$target';
          resolved.replaceAll(RegExp(r'/+'), '/');
          if (await File(resolved).exists()) {
            try { await File(resolved).copy(outPath); } catch (_) {}
          }
        }
        count++;
        if (count % 100 == 0) _pulseExtract(count, total);
        continue;
      }

      if (entry.isFile) {
        final data = entry.content;
        if (data.isNotEmpty) {
          await File(outPath).writeAsBytes(data);
        } else {
          // Hardlink o archivo vacío legítimo
          await File(outPath).writeAsString('');
        }
        count++;
        if (count % 100 == 0) _pulseExtract(count, total);
        continue;
      }

      count++;
    }
  }

  void _pulseExtract(int count, int total) {
    if (total > 0) {
      _downloadProgress = 0.55 + (count / total) * 0.20;
      _statusMessage = 'Extrayendo ${(count * 100 / total).toInt()}%';
      notifyListeners();
    }
  }

  // ─── Hacer ejecutables los binarios clave ───
  Future<void> _chmodCritical(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (await d.exists()) {
        try {
          final files = await d.list().toList();
          for (final f in files) {
            if (f is File) {
              final name = f.path.split('/').last;
              if (name.contains('.so') || name.length < 20) {
                try { await Process.run('chmod', ['755', f.path]); } catch (_) {}
              }
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

    final bbPath = '${await _appDir}/bin/busybox';
    final hasBb = await File(bbPath).exists() && await File(bbPath).length() > 0;
    final hasSh = await File('$rootfs/bin/sh').exists()
                  && await File('$rootfs/bin/sh').length() > 0;

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

      // 3: linker + rootfs/bin/sh
      if (linker != null && hasSh) {
        try {
          final result = await Process.run(
            linker, ['$rootfs/bin/sh', '-c', command],
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

      // 4: /system/bin/sh
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

  // ─── Descarga ───
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
