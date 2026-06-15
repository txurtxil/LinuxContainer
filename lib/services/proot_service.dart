import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ProotService extends ChangeNotifier {
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
  String? _busyboxPath;
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
        if (await sh.exists()) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          notifyListeners();
          return true;
        }
      }

      // ¿Ya tenemos busybox?
      final bb = File('$appDir/bin/busybox');
      if (await bb.exists()) {
        _busyboxPath = bb.path;
        _initialized = true;
        _statusMessage = 'Linux listo (modo básico)';
        notifyListeners();
        return true;
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
    _statusMessage = 'Iniciando setup…';
    _lastOutput = '';
    notifyListeners();

    try {
      final appDir = await _appDir;
      _rootfsPath = '$appDir/rootfs';

      // Crear directorios base
      await Directory(appDir).create(recursive: true);
      await Directory('$appDir/bin').create(recursive: true);
      await Directory(_rootfsPath!).create(recursive: true);

      // ── Paso 1: Descargar BusyBox estático ──
      _downloadProgress = 0.05;
      _statusMessage = 'Descargando BusyBox…';
      notifyListeners();

      final bbPath = '$appDir/bin/busybox';
      if (!await File(bbPath).exists()) {
        await _downloadFile(
          'https://busybox.net/downloads/binaries/1.36.1/busybox-armv8l',
          bbPath,
        );
        // Hacer ejecutable
        await Process.run('chmod', ['755', bbPath]);
      }
      _busyboxPath = bbPath;

      // ── Paso 2: Crear symlinks de busybox ──
      _downloadProgress = 0.15;
      _statusMessage = 'Instalando comandos base…';
      notifyListeners();

      await _installBusyboxLinks('$appDir/bin');

      // ── Paso 3: Descargar PROOT estático ──
      _downloadProgress = 0.25;
      _statusMessage = 'Descargando PROOT…';
      notifyListeners();

      final prootPath = '$appDir/bin/proot';
      if (!await File(prootPath).exists()) {
        try {
          await _downloadFile(
            'https://github.com/proot-me/proot/releases/download/v5.4.0/proot-v5.4.0-aarch64-static',
            prootPath,
          );
          await Process.run('chmod', ['755', prootPath]);
        } catch (e) {
          _lastOutput += 'PROOT download falló: $e. Usando modo sin PROOT.\n';
        }
      }
      if (await File(prootPath).exists()) {
        _prootPath = prootPath;
      }

      // ── Paso 4: Descargar rootfs Debian ──
      _downloadProgress = 0.35;
      _statusMessage = 'Descargando Debian rootfs…';
      notifyListeners();

      final rootfsTgz = File('$appDir/rootfs.tar.xz');
      if (!await rootfsTgz.exists()) {
        // Intentar varios mirrors
        bool downloaded = false;
        final urls = [
          'https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-arm64v8/bookworm/rootfs.tar.xz',
          'https://cloud.debian.org/images/cloud/bookworm/20250331-1966/debian-12-arm64-20250331-1966.tar.xz',
        ];
        for (final url in urls) {
          try {
            await _downloadFile(url, rootfsTgz.path);
            downloaded = true;
            break;
          } catch (_) {
            continue;
          }
        }
        if (!downloaded) {
          throw Exception('No se pudo descargar rootfs Debian');
        }
      }

      // ── Paso 5: Extraer rootfs con BusyBox tar ──
      _downloadProgress = 0.55;
      _statusMessage = 'Extrayendo rootfs…';
      notifyListeners();

      // Usar busybox tar para extraer (evita bugs de dart:io archive)
      final hasTar = await File('$appDir/bin/tar').exists();
      if (hasTar) {
        await _runBusybox([
          'tar', '-xf', rootfsTgz.path, '-C', _rootfsPath!,
          '--no-same-permissions', '--no-same-owner',
        ]);
      } else {
        // Fallback: extracción con Dart
        _statusMessage = 'Extrayendo con Dart…';
        notifyListeners();
        await _extractTarXz(rootfsTgz.path, _rootfsPath!);
      }

      // ── Paso 6: Post-configuración ──
      _downloadProgress = 0.75;
      _statusMessage = 'Configurando entorno…';
      notifyListeners();

      // /etc/resolv.conf (DNS)
      final etcDir = Directory('$_rootfsPath/etc');
      await etcDir.create(recursive: true);
      await File('$_rootfsPath/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
      );

      // /etc/hosts
      await File('$_rootfsPath/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n',
      );

      // /etc/apt/sources.list si no existe
      final aptDir = Directory('$_rootfsPath/etc/apt');
      await aptDir.create(recursive: true);
      final sources = File('$_rootfsPath/etc/apt/sources.list');
      if (!await sources.exists()) {
        await sources.writeAsString(
          'deb http://deb.debian.org/debian bookworm main contrib non-free\n'
          'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free\n'
          'deb http://deb.debian.org/debian bookworm-updates main contrib non-free\n',
        );
      }

      // Asegurar /bin/sh
      if (!await File('$_rootfsPath/bin/sh').exists()) {
        final bb = _busyboxPath ?? '$appDir/bin/busybox';
        if (await File(bb).exists()) {
          await File('$_rootfsPath/bin/sh').parent.create(recursive: true);
          await File(bb).copy('$_rootfsPath/bin/busybox');
          await Process.run(bb, ['--install', '-s', '$_rootfsPath/bin']);
        }
      }

      // Verificar que tenemos sh
      final shExists = await File('$_rootfsPath/bin/sh').exists();

      _downloadProgress = 1.0;
      _initialized = shExists;
      _statusMessage = shExists
          ? 'Debian Linux listo'
          : 'Error: /bin/sh no encontrado en rootfs';
      _lastOutput += _statusMessage;
    } catch (e) {
      _statusMessage = 'Error: $e';
      _lastOutput += '\nError: $e';
      _initialized = false;
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  // ─── Instalar symlinks de busybox ───
  Future<void> _installBusyboxLinks(String binDir) async {
    final bb = _busyboxPath;
    if (bb == null) return;

    final applets = [
      'sh', 'bash', 'ls', 'cp', 'mv', 'rm', 'mkdir', 'chmod', 'chown',
      'cat', 'echo', 'grep', 'sed', 'awk', 'cut', 'tr', 'sort', 'uniq',
      'head', 'tail', 'wc', 'tee', 'find', 'xargs', 'clear',
      'tar', 'gzip', 'gunzip', 'bzip2', 'unxz', 'xzcat',
      'wget', 'curl', 'ping', 'netstat', 'nslookup', 'dig',
      'ifconfig', 'route', 'ip', 'arp',
      'kill', 'killall', 'ps', 'top', 'pidof',
      'mount', 'umount', 'df', 'du', 'free',
      'vi', 'nano', 'less', 'more',
      'date', 'cal', 'sleep', 'time', 'env',
      'whoami', 'id', 'uname', 'uptime',
      'ln', 'readlink', 'realpath',
    ];

    // Si no existe la carpeta destino, usar busybox --install
    await Directory(binDir).create(recursive: true);

    // Intentar --install primero (más rápido)
    try {
      await Process.run(bb, ['--install', '-s', binDir]);
    } catch (_) {
      // Fallback manual
      for (final applet in applets) {
        final link = File('$binDir/$applet');
        if (!await link.exists()) {
          try {
            await link.parent.create(recursive: true);
            await link.createSync(recursive: false);
            // En Android no podemos crear symlinks fácilmente,
            // usamos un script que redirige a busybox
            final script = '#!/system/bin/sh\n"{BB}" {APPLET} "{ARGS}"\n'
              .replaceFirst('{BB}', bb)
              .replaceFirst('{APPLET}', applet)
              .replaceFirst('{ARGS}', r'$@');
          await link.writeAsString(script);
            await Process.run('chmod', ['755', link.path]);
          } catch (_) {
            // ignorar errores de symlinks en Android
          }
        }
      }
    }
  }

  // ─── Ejecutar un comando con busybox ───
  Future<String> _runBusybox(List<String> args, {Duration timeout = const Duration(seconds: 60)}) async {
    final bb = _busyboxPath;
    if (bb == null) return 'Error: BusyBox no disponible';

    try {
      // Intentar con linker del sistema (noexec bypass)
      final linker = (await File('/system/bin/linker64').exists())
          ? '/system/bin/linker64'
          : (await File('/system/bin/linker').exists())
              ? '/system/bin/linker'
              : null;

      if (linker != null) {
        final result = await Process.run(
          linker, [bb, ...args],
          environment: {
            'PATH': '$bb:${_rootfsPath ?? ""}/usr/bin:${_rootfsPath ?? ""}/bin:/system/bin:/system/xbin',
          },
        ).timeout(timeout);
        return '${result.stdout}${result.stderr}';
      }

      // Fallback directo
      final result = await Process.run(bb, args).timeout(timeout);
      return '${result.stdout}${result.stderr}';
    } catch (e) {
      return 'Error ejecutando busybox: $e';
    }
  }

  // ─── Ejecutar comando principal ───
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized) {
      return 'Error: Linux no inicializado.\n'
          'Pulsa "Setup Linux" en la pantalla de inicio.\n';
    }

    final rootfs = _rootfsPath;
    final proot = _prootPath;
    final bb = _busyboxPath;

    try {
      // ── Estrategia 1: PROOT + rootfs ──
      if (proot != null && rootfs != null && await File(proot).exists()) {
        try {
          final linker = '/system/bin/linker64';
          final hasLinker = await File(linker).exists();

          final args = [
            '-0',                           // fake root
            '-r', rootfs,                   // rootfs path
            '-b', '/proc',                  // bind proc
            '-b', '/sys',                   // bind sys
            '-b', '/dev',                   // bind dev
            '-b', '/system',                // Android system (linker)
            '-w', '/root',                  // working dir
            '/usr/bin/env',
            'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME=/root',
            'TERM=xterm-256color',
            'sh', '-c', command,
          ];

          final exec = hasLinker ? [linker, proot, ...args] : [proot, ...args];

          final result = await Process.run(
            exec.removeAt(0), exec,
            workingDirectory: rootfs,
          ).timeout(timeout);

          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'PROOT falló ($e), intentando BusyBox…\n';
          // Fall through
        }
      }

      // ── Estrategia 2: Linker + BusyBox sh ──
      if (bb != null && await File(bb).exists()) {
        final linker = '/system/bin/linker64';
        final hasLinker = await File(linker).exists();

        if (hasLinker) {
          final result = await Process.run(
            linker, [bb, 'sh', '-c', command],
            environment: {
              'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin',
              'HOME': '/root',
              'TERM': 'xterm-256color',
            },
          ).timeout(timeout);

          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        }

        // Directo
        final result = await Process.run(
          bb, ['sh', '-c', command],
          environment: {
            'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME': '/root',
            'TERM': 'xterm-256color',
          },
        ).timeout(timeout);

        final out = result.stdout as String;
        final err = result.stderr as String;
        _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
        return _lastOutput;
      }

      // ── Estrategia 3: rootfs/bin/sh directo ──
      if (rootfs != null) {
        final shPath = '$rootfs/bin/sh';
        if (await File(shPath).exists()) {
          final linker = '/system/bin/linker64';
          if (await File(linker).exists()) {
            final result = await Process.run(
              linker, [shPath, '-c', command],
              environment: {
                'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin:/system/bin:/system/xbin',
                'HOME': '$rootfs/root',
                'TERM': 'xterm-256color',
                'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
              },
            ).timeout(timeout);

            final out = result.stdout as String;
            final err = result.stderr as String;
            _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
            return _lastOutput;
          }
        }
      }

      return 'Error: No se pudo ejecutar el comando.\n'
          'Asegúrate de que el entorno Linux esté instalado.\n';
    } on TimeoutException {
      return '\n[Timeout] El comando excedió ${timeout.inSeconds}s\n';
    } catch (e) {
      _lastOutput = '\n[Error] $e\n';
      _statusMessage = 'Error de ejecución';
      notifyListeners();
      return _lastOutput;
    }
  }

  // ─── Extraer tar.xz con Dart (fallback) ───
  Future<void> _extractTarXz(String tarPath, String destPath) async {
    _statusMessage = 'Leyendo archivo…';
    notifyListeners();

    final bytes = await File(tarPath).readAsBytes();

    // Intentar detectar compresión
    List<int> tarBytes;
    if (bytes.length > 3 &&
        bytes[0] == 0xFD && bytes[1] == 0x37 && bytes[2] == 0x7A) {
      // XZ magic bytes → no podemos descomprimir fácilmente en Dart puro
      _statusMessage = 'Formato XZ detectado. BusyBox tar necesario.';
      notifyListeners();
      // Buscar busybox tar en varias ubicaciones
      for (final candidate in [
        _busyboxPath,
        '$_rootfsPath/bin/tar',
        '/system/bin/tar',
      ]) {
        if (candidate != null && await File(candidate).exists()) {
          final result = await Process.run(candidate, [
            '-xf', tarPath, '-C', destPath,
            '--no-same-permissions', '--no-same-owner',
          ]);
          _lastOutput += 'tar exit: ${result.exitCode}\n${result.stderr}';
          return;
        }
      }
      throw Exception('No hay tar disponible para extraer XZ');
    }

    // GZip
    _statusMessage = 'Descomprimiendo…';
    notifyListeners();
    tarBytes = await _gunzip(bytes);

    _statusMessage = 'Extrayendo archivos…';
    notifyListeners();
    await _untar(tarBytes, destPath);
  }

  Future<List<int>> _gunzip(List<int> data) async {
    try {
      final proc = await Process.start(
        _busyboxPath ?? 'gzip', ['-d'],
      );
      proc.stdin.add(data);
      await proc.stdin.close();
      final output = await proc.stdout.toList();
      await proc.stderr.drain();
      final code = await proc.exitCode;
      if (code == 0 && output.isNotEmpty) {
        return output.expand((x) => x).toList();
      }
    } catch (_) {}
    return data;
  }

  Future<void> _untar(List<int> data, String destPath) async {
    if (_busyboxPath != null && await File(_busyboxPath!).exists()) {
      final tarPath = '${await _appDir}/tmp.tar';
      await File(tarPath).writeAsBytes(data);
      await _runBusybox([
        'tar', '-xf', tarPath, '-C', destPath,
        '--no-same-permissions', '--no-same-owner',
      ]);
      await File(tarPath).delete();
      return;
    }
    throw Exception('No hay tar disponible');
  }

  // ─── Descarga de archivos ───
  Future<void> _downloadFile(String url, String path) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} descargando $url');
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;

      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = 0.25 + (receivedBytes / totalBytes) * 0.30;
          notifyListeners();
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
    _busyboxPath = null;
    _prootPath = null;
    _rootfsPath = null;
    _statusMessage = 'Entorno reiniciado';
    notifyListeners();
  }
}
