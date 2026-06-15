import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  String? _rootfsPath;

  // Constantes
  static const String _apkUrl =
      'https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.10/aarch64/apk.static';
  static const String _prootUrl =
      'https://github.com/proot-me/proot/releases/download/v5.4.0/proot-v5.4.0-aarch64-static';
  static const String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine';
  static const String _alpineBranch = 'v3.21';
  static const String _minirootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz';

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
        if (await sh.exists()) {
          final st = await sh.stat();
          if (st.size > 0 && st.mode & 0x40 != 0) {
            _initialized = true;
            _statusMessage = 'Linux listo';
            notifyListeners();
            return true;
          }
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

      // ───── 1. apk.static ─────
      if (await _setupWithApkStatic(appDir, rootfs)) {
        _lastOutput += 'Rootfs creado con apk.static\n';
      } else {
        _lastOutput += 'apk.static falló, usando minirootfs\n';
        if (!await _setupWithMinirootfs(appDir, rootfs)) {
          throw Exception('No se pudo crear el rootfs');
        }
      }

      // ───── 2. Configuración común ─────
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // ───── 3. Hacer ejecutables ─────
      await _chmodBins(rootfs);

      // ───── 4. PROOT ─────
      _downloadProgress = 0.85;
      _statusMessage = 'Descargando PROOT…';
      notifyListeners();

      final prootPath = '$appDir/proot';
      if (!await File(prootPath).exists()) {
        try {
          await _downloadFile(_prootUrl, prootPath, 0.85, 0.95);
          await Process.run('chmod', ['755', prootPath]);
        } catch (e) {
          _lastOutput += 'PROOT no disponible: $e\n';
        }
      }

      // ───── 5. Verificación final ─────
      final shOk = await File('$rootfs/bin/sh').exists() &&
                   await File('$rootfs/bin/sh').length() > 0;

      _downloadProgress = 1.0;
      _initialized = shOk;
      _statusMessage = shOk
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

  // ───── Método 1: apk.static (estático, sin dependencias) ─────
  Future<bool> _setupWithApkStatic(String appDir, String rootfs) async {
    _statusMessage = 'Descargando apk-tools…';
    notifyListeners();

    final apkBin = '$appDir/apk';
    if (!await File(apkBin).exists()) {
      try {
        await _downloadFile(_apkUrl, apkBin, 0.05, 0.20);
        await Process.run('chmod', ['755', apkBin]);
      } catch (e) {
        _lastOutput += 'Error descargando apk.static: $e\n';
        return false;
      }
    }

    _downloadProgress = 0.20;
    _statusMessage = 'Configurando repositorios Alpine…';
    notifyListeners();

    // keys
    await Directory('$rootfs/etc/apk/keys').create(recursive: true);
    final keys = <String, String>{
      'alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub':
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1yHJxQgsHQREclQu4Ohe'
          'qxTxd1tHcNnvnQTu/UrTky8wWvgXT+jpveroeWWnzmsYlDI93eLI2ORakxb3gA2O'
          'Q0Ry4ws8vhaxLQGC74uQR5+/yYrLuTKydFzuPaS1dK19qJPXB8GMdmFOijnXX4SA'
          'jixuHLe1WW7kZVtjL7nufvpXkWBGjsfrvskdNA/5MfxAeBbqPgaq0QMEfxMAn6/R'
          'L5kNepi/Vr4S39Xvf2DzWkTLEK8pcnjNkt9/aafhWqFVW7m3HCAII6h/qlQNQKSo'
          'GuH34Q8GsFG30izUENV9avY7hSLq7nggsvknlNBZtFUcmGoQrtx3FmyYsIC8/R+B'
          'ywIDAQAB',
      'alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub':
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwlzMkl7b5PBdfMzGdCT0'
          'cGloRr5xGgVmsdq5EtJvFkFAiN8Ac9MCFy/vAFmS8/7ZaGOXoCDWbYVLTLOO2qtX'
          'yHRl+7fJVh2N6qrDDFPmdgCi8NaE+3rITWXGrrQ1spJ0B6HIzTDNEjRKnD4xyg4j'
          'g01FMcJTU6E+V2JBY45CKN9dWr1JDM/nei/Pf0byBJlMp/mSSfjodykmz4Oe13xB'
          'Ca1WTwgFykKYthoLGYrmo+LKIGpMoeEbY1kuUe04UiDe47l6Oggwnl+8XD1MeRWY'
          'sWgj8sF4dTcSfCMavK4zHRFFQbGp/YFJ/Ww6U9lA3Vq0wyEI6MCMQnoSMFwrbgZw'
          'wwIDAQAB',
    };
    await Directory('$rootfs/etc/apk/keys').create(recursive: true);
    for (final entry in keys.entries) {
      await File('$rootfs/etc/apk/keys/${entry.key}').writeAsString(
        '-----BEGIN PUBLIC KEY-----\n'
        '${entry.value}\n'
        '-----END PUBLIC KEY-----\n',
      );
    }

    // repositories
    await File('$rootfs/etc/apk/repositories').writeAsString(
      '$_alpineMirror/$_alpineBranch/main\n'
      '$_alpineMirror/$_alpineBranch/community\n',
    );

    _downloadProgress = 0.25;
    _statusMessage = 'Instalando paquetes base…';
    notifyListeners();

    try {
      final result = await Process.run(
        apkBin, [
          '--root', rootfs,
          '--arch', 'aarch64',
          '--initdb',
          '--no-progress',
          'add',
          'alpine-baselayout',
          'busybox',
          'musl-utils',
          'alpine-release',
          'apk-tools',
        ],
      ).timeout(const Duration(seconds: 180));

      _lastOutput += 'apk exit: ${result.exitCode}\n';

      if (result.exitCode != 0) {
        _lastOutput += '${result.stderr}\n';
        return false;
      }

      // Verificar sh
      final shFile = File('$rootfs/bin/sh');
      if (!await shFile.exists() || await shFile.length() == 0) {
        // busybox --install para crear los symlinks/applets
        final bbFile = File('$rootfs/bin/busybox');
        if (await bbFile.exists() && await bbFile.length() > 0) {
          await bbFile.copy('$rootfs/bin/sh');
          await Process.run('chmod', ['755', '$rootfs/bin/sh']);
        }
      }

      return true;
    } catch (e) {
      _lastOutput += 'apk.static excepción: $e\n';
      return false;
    }
  }

  // ───── Método 2: Minirootfs (fallback) ─────
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    _statusMessage = 'Descargando minirootfs Alpine…';
    notifyListeners();

    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try {
        await _downloadFile(_minirootfsUrl, tgzPath, 0.25, 0.50);
      } catch (e) {
        _lastOutput += 'Error descargando minirootfs: $e\n';
        return false;
      }
    }

    _downloadProgress = 0.50;
    _statusMessage = 'Extrayendo minirootfs…';
    notifyListeners();

    // Usar toybox/toolbox tar del sistema (maneja hardlinks)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          await Process.run(tb, ['tar', '-xf', tgzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 120));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) {
            _lastOutput += 'Extraído con $tb\n';
            return true;
          }
        } catch (e) {
          _lastOutput += '$tb falló: $e\n';
        }
      }
    }

    // Sin toybox ni toolbox (imposible en Android moderno)
    _lastOutput += 'No hay tar disponible en el sistema\n';
    return false;
  }

  // ─── Chmod ───
  Future<void> _chmodBins(String rootfs) async {
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
    final linker = (await File('/system/bin/linker64').exists())
        ? '/system/bin/linker64'
        : (await File('/system/bin/linker').exists())
            ? '/system/bin/linker'
            : null;

    // Buscar shell
    final candidates = [
      '$rootfs/bin/sh',
      '$rootfs/bin/busybox',
    ];

    String? shellPath;
    for (final p in candidates) {
      if (await File(p).exists() && await File(p).length() > 0) {
        shellPath = p;
        break;
      }
    }

    // Si no hay shell en rootfs, usar system sh
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
      } catch (e) {
        _lastOutput = 'system sh falló: $e\n';
      }
    }

    if (shellPath == null) {
      return 'Error: No hay shell disponible.\n';
    }

    try {
      // Linker del sistema + shell
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

      // Directo
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
    _rootfsPath = null;
    _statusMessage = 'Entorno reiniciado';
    notifyListeners();
  }
}
