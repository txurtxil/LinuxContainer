import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier {
  // ─── Singleton: todos los servicios comparten el mismo estado ───
  static final ProotService _instance = ProotService._internal();
  factory ProotService() => _instance;
  ProotService._internal();

  // ─── Estado ───
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

  // ─── Rutas ───
  String? _prootPath;
  String? _rootfsPath;

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  // ─── Comprobación de entorno ───
  Future<bool> checkEnvironment() async {
    try {
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
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

  // ─── Setup completo ───
  Future<void> setupEnvironment() async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _statusMessage = 'Iniciando…';
    _lastOutput = '';
    notifyListeners();

    try {
      final appDir = await _appDir;
      _rootfsPath = '$appDir/rootfs';

      // Crear directorios base
      await Directory(appDir).create(recursive: true);
      await Directory(_rootfsPath!).create(recursive: true);

      // ── Paso 1: Descargar Alpine minirootfs (tar.gz) ──
      _downloadProgress = 0.1;
      _statusMessage = 'Descargando Alpine Linux…';
      notifyListeners();

      final tgzPath = '$appDir/rootfs.tar.gz';
      if (!await File(tgzPath).exists()) {
        await _downloadFile(
          'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz',
          tgzPath,
          0.1, 0.5,  // startWeight, endWeight
        );
      }

      // ── Paso 2: Extraer rootfs ──
      _downloadProgress = 0.5;
      _statusMessage = 'Extrayendo rootfs…';
      notifyListeners();

      if (!await File('$_rootfsPath/bin/sh').exists()) {
        await _extractTarGz(tgzPath, _rootfsPath!);
      }

      // ── Paso 3: Verificar bin/sh y aplicar permisos ──
      _downloadProgress = 0.65;
      _statusMessage = 'Configurando permisos…';
      notifyListeners();

      // Hacer ejecutables los binarios clave
      await _chmodRecursive(_rootfsPath!);

      // Verificar que sh se extrajo correctamente
      final shFile = File('$_rootfsPath/bin/sh');
      final shOk = await shFile.exists() && await shFile.length() > 0;
      if (!shOk) {
        // Intentar extraer busybox a mano como fallback
        _statusMessage = 'Recuperando: extrayendo busybox manual…';
        notifyListeners();
        await _extractBusyboxManually(tgzPath, _rootfsPath!);
      }

      // ── Paso 4: Configurar red ──
      _downloadProgress = 0.75;
      _statusMessage = 'Configurando red…';
      notifyListeners();

      await Directory('$_rootfsPath/etc').create(recursive: true);
      await File('$_rootfsPath/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
      );
      await File('$_rootfsPath/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n',
      );

      // ── Paso 5: Descargar PROOT estático ──
      _downloadProgress = 0.85;
      _statusMessage = 'Descargando PROOT…';
      notifyListeners();

      final prootPath = '$appDir/proot';
      if (!await File(prootPath).exists()) {
        try {
          await _downloadFile(
            'https://github.com/proot-me/proot/releases/download/v5.4.0/proot-v5.4.0-aarch64-static',
            prootPath,
            0.85, 0.95,
          );
          await Process.run('chmod', ['755', prootPath]);
        } catch (e) {
          _lastOutput += 'PROOT download falló: $e (se usará modo básico)\n';
        }
      }
      if (await File(prootPath).exists()) {
        _prootPath = prootPath;
      }

      // ── Verificación final ──
      final shExists = await File('$_rootfsPath/bin/sh').exists() &&
                       await File('$_rootfsPath/bin/sh').length() > 0;

      _downloadProgress = 1.0;
      _initialized = shExists;
      _statusMessage = shExists
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

  // ─── Extraer tar.gz con soporte correcto de hardlinks ───
  Future<void> _extractTarGz(String tarPath, String destPath) async {
    // Estrategia 1: Usar toybox tar del sistema (funciona en Android)
    for (final tarBin in ['/system/bin/toybox', '/system/bin/toolbox', '/system/bin/busybox']) {
      if (await File(tarBin).exists()) {
        try {
          final result = await Process.run(
            tarBin, ['tar', '-xf', tarPath, '-C', destPath,
                     '--no-same-permissions', '--no-same-owner'],
          );
          if (result.exitCode == 0) {
            _lastOutput += 'Extraído con $tarBin\n';
            return;
          }
        } catch (_) {}
      }
    }

    // Estrategia 2: Extracción con Dart archive (fix hardlinks)
    _statusMessage = 'Extrayendo con Dart…';
    notifyListeners();

    final bytes = await File(tarPath).readAsBytes();
    final gzipBytes = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gzipBytes);

    int extracted = 0;
    final total = archive.length;

    // Mapa de inodos -> primer path que lo contiene (para hardlinks)
    final Map<int, String> inodeMap = {};

    for (final entry in archive) {
      String name = entry.name;
      if (name.startsWith('./')) name = name.substring(2);
      if (name.isEmpty || name == '.') continue;

      final outPath = '$destPath/$name';

      // ── Directorios ──
      if (name.endsWith('/')) {
        await Directory(outPath).create(recursive: true);
        extracted++;
        _updateExtractionProgress(extracted, total);
        continue;
      }

      // Asegurar directorio padre
      await Directory(outPath).parent.create(recursive: true);

      // ── Symlinks y Hardlinks ──
      final linkTarget = (entry is TarFile) ? entry.linkName : '';
      if (linkTarget.isNotEmpty || entry.isSymbolicLink) {
        // SYMLINK o HARDLINK
        final target = entry.isSymbolicLink
            ? (entry.symbolicLink ?? linkTarget)
            : linkTarget;

        if (target.isNotEmpty) {
          // Resolver path relativo
          String resolved;
          if (target.startsWith('/')) {
            resolved = '$destPath$target';
          } else {
            final parentDir = Directory(outPath).parent.path;
            resolved = '$parentDir/$target';
          }
          resolved = resolved.replaceAll(RegExp(r'/+'), '/');

          // Si el target existe, copiar en lugar de hacer symlink
          // (Android no permite symlinks fácilmente en app data)
          if (await File(resolved).exists()) {
            try {
              await File(resolved).copy(outPath);
            } catch (_) {
              // fallback: crear archivo vacío
              await File(outPath).writeAsBytes(entry.content);
            }
          } else {
            // Escribir contenido si tiene (puede estar vacío para hardlinks)
            final data = entry.content;
            if (data.isNotEmpty) {
              await File(outPath).writeAsBytes(data);
            } else {
              // Hardlink sin contenido → archivo vacío
              await File(outPath).writeAsString('');
            }
          }
        } else {
          await File(outPath).writeAsBytes(entry.content);
        }
        extracted++;
        _updateExtractionProgress(extracted, total);
        continue;
      }

      // ── Archivos normales ──
      if (entry.isFile) {
        final data = entry.content;
        if (data.isNotEmpty) {
          await File(outPath).writeAsBytes(data);
        } else {
          // Podría ser hardlink sin linkName (archive bug)
          // Intentar detectar: si tamaño 0 y no es directorio, crear vacío
          await File(outPath).writeAsString('');
        }
        extracted++;
        _updateExtractionProgress(extracted, total);
        continue;
      }

      // Otros tipos (desconocido)
      extracted++;
      _updateExtractionProgress(extracted, total);
    }
  }

  void _updateExtractionProgress(int current, int total) {
    if (total > 0 && current % 50 == 0) {
      _downloadProgress = 0.5 + (current / total) * 0.15;
      _statusMessage = 'Extrayendo ${(current * 100 / total).toInt()}%';
      notifyListeners();
    }
  }

  // ─── Extraer busybox manualmente si la extracción normal falla ───
  Future<void> _extractBusyboxManually(String tarPath, String destPath) async {
    try {
      final bytes = await File(tarPath).readAsBytes();
      final gzipBytes = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gzipBytes);

      for (final entry in archive) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name == 'bin/busybox' && entry.isFile) {
          final data = entry.content;
          if (data.isNotEmpty) {
            await Directory('$destPath/bin').create(recursive: true);
            await File('$destPath/bin/busybox').writeAsBytes(data);
            await Process.run('chmod', ['755', '$destPath/bin/busybox']);
            // Crear symlink de sh a busybox
            final script = '#!/system/bin/sh\n'
                '$destPath/bin/busybox sh "\$@"\n';
            await File('$destPath/bin/sh').writeAsString(script);
            await Process.run('chmod', ['755', '$destPath/bin/sh']);
            _lastOutput += 'busybox extraído manualmente\n';
            return;
          }
        }
      }
    } catch (e) {
      _lastOutput += 'Error en extracción manual: $e\n';
    }
  }

  // ─── Hacer ejecutables los binarios en rootfs ───
  Future<void> _chmodRecursive(String dirPath) async {
    final dir = Directory(dirPath);
    try {
      final entities = await dir.list(recursive: true, followLinks: false).toList();
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          // binarios comunes que deben ser ejecutables
          if ([
            'sh', 'busybox', 'apk', 'init',
          ].contains(name) || name.contains('.so')) {
            try {
              await Process.run('chmod', ['755', entity.path]);
            } catch (_) {}
          }
        }
      }
      // También hacer ejecutables todo /bin /sbin /usr/bin
      for (final binDir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
        final d = Directory('$dirPath$binDir');
        if (await d.exists()) {
          try {
            final files = await d.list().toList();
            for (final f in files) {
              if (f is File) {
                try {
                  await Process.run('chmod', ['755', f.path]);
                } catch (_) {}
              }
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ─── Ejecutar comando en el entorno Linux ───
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\nPulsa "Setup Linux" primero.\n';
    }

    final rootfs = _rootfsPath!;
    final proot = _prootPath;

    // Detectar linker del sistema Android
    final linker = (await File('/system/bin/linker64').exists())
        ? '/system/bin/linker64'
        : (await File('/system/bin/linker').exists())
            ? '/system/bin/linker'
            : null;

    final busyboxPath = '$rootfs/bin/busybox';
    final shPath = '$rootfs/bin/sh';
    final hasBusybox = await File(busyboxPath).exists() && await File(busyboxPath).length() > 0;
    final hasSh = await File(shPath).exists() && await File(shPath).length() > 0;

    try {
      // ── Estrategia 1: PROOT (entorno completo con fakeroot) ──
      if (proot != null && await File(proot).exists() && linker != null) {
        try {
          final args = [
            '-0',                           // fake root
            '-r', rootfs,                   // rootfs path
            '-b', '/proc',                  // bind proc
            '-b', '/sys',                   // bind sys
            '-b', '/dev',                   // bind dev
            '-b', '/system',                // Android system (linker64)
            '-w', '/root',                  // working dir
            '/usr/bin/env',
            'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME=/root',
            'TERM=xterm-256color',
            'sh', '-c', command,
          ];

          final result = await Process.run(
            linker, [proot, ...args],
            workingDirectory: rootfs,
            environment: {
              'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
            },
          ).timeout(timeout);

          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'PROOT falló: $e\n';
          // fall through
        }
      }

      // ── Estrategia 2: Linker del sistema + busybox ──
      if (linker != null && hasBusybox) {
        try {
          final result = await Process.run(
            linker, [busyboxPath, 'sh', '-c', command],
            environment: {
              'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                      '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin',
              'HOME': '$rootfs/root',
              'TERM': 'xterm-256color',
              'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
              'PREFIX': rootfs,
            },
            workingDirectory: rootfs,
          ).timeout(timeout);

          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'Linker+Busybox falló: $e\n';
        }
      }

      // ── Estrategia 3: Linker + sh directo ──
      if (linker != null && hasSh) {
        try {
          final result = await Process.run(
            linker, [shPath, '-c', command],
            environment: {
              'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                      '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin',
              'HOME': '$rootfs/root',
              'TERM': 'xterm-256color',
              'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
            },
            workingDirectory: rootfs,
          ).timeout(timeout);

          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'Linker+sh falló: $e\n';
        }
      }

      // ── Estrategia 4: /system/bin/sh + rootfs en PATH ──
      if (await File('/system/bin/sh').exists()) {
        final result = await Process.run(
          '/system/bin/sh', ['-c', command],
          environment: {
            'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                    '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin:'
                    '/system/bin:/system/xbin',
            'HOME': '$rootfs/root',
            'TERM': 'xterm-256color',
            'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
          },
          workingDirectory: rootfs,
        ).timeout(timeout);

        final out = result.stdout as String;
        final err = result.stderr as String;
        _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
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

  // ─── Descarga de archivos con seguimiento de progreso ───
  Future<void> _downloadFile(
    String url, String path,
    double startWeight, double endWeight,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode} descargando $url',
        );
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;

      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = startWeight +
              (receivedBytes / totalBytes) * (endWeight - startWeight);
          if (receivedBytes % (1024 * 512) < chunk.length) {
            // Actualizar cada ~512KB
            notifyListeners();
          }
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
  }

  // ─── Limpieza ───
  Future<void> resetEnvironment() async {
    final appDir = await _appDir;
    try {
      await Directory(appDir).delete(recursive: true);
    } catch (_) {}
    _initialized = false;
    _prootPath = null;
    _rootfsPath = null;
    _statusMessage = 'Entorno reiniciado';
    notifyListeners();
  }
}
