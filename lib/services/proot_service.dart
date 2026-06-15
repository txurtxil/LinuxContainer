import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
// ignore_for_file: curly_braces_in_flow_control_structures

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

  // Constantes
  static const String _apkUrl =
      'https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.10/aarch64/apk.static';
  static const String _prootUrl =
      'https://github.com/proot-me/proot/releases/download/v5.4.0/proot-v5.4.0-aarch64-static';
  static const String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine';
  static const String _alpineBranch = 'v3.21';
  static const String _minirootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz';
  static const String _debianRootfsUrl =
      'https://cloud.debian.org/images/cloud/bookworm/20250331-1966/debian-12-arm64-20250331-1966.tar.xz';

  // Linker del sistema Android (para saltar noexec)
  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  // ─── Comprobación ───
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
          if (st.size > 0 && st.mode & 0x40 != 0) {
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

  // ─── Setup ───
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

      // Probar métodos en orden
      bool ok = false;

      // 1: Asset embeeded (si existe)
      ok = await _setupFromAsset(rootfs);
      if (ok) _logMsg('✓ Rootfs desde asset');

      // 2: apk.static
      if (!ok) {
        ok = await _setupWithApkStatic(appDir, rootfs);
        if (ok) _logMsg('✓ Rootfs con apk.static');
      }

      // 3: Minirootfs tar.gz
      if (!ok) {
        ok = await _setupWithMinirootfs(appDir, rootfs);
        if (ok) _logMsg('✓ Rootfs desde minirootfs');
      }

      // 4: Debian rootfs
      if (!ok) {
        ok = await _setupWithDebianRootfs(appDir, rootfs);
        if (ok) _logMsg('✓ Rootfs Debian');
      }

      if (!ok) {
        throw Exception('No se pudo crear el rootfs (probados: asset, apk.static, minirootfs, Debian)');
      }

      // Configuración común
      _downloadProgress = 0.80;
      _statusMessage = 'Configurando red…';
      notifyListeners();

      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // Para Debian: configurar apt
      if (await File('$rootfs/etc/apt').exists()) {
        _logMsg('Rootfs Debian detectado, configurando apt sources');
        final aptDir = Directory('$rootfs/etc/apt');
        await aptDir.create(recursive: true);
        if (!await File('$rootfs/etc/apt/sources.list').exists()) {
          await File('$rootfs/etc/apt/sources.list').writeAsString(
            'deb http://deb.debian.org/debian bookworm main contrib non-free\n'
            'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free\n'
            'deb http://deb.debian.org/debian bookworm-updates main contrib non-free\n');
        }
      }

      await _chmodBins(rootfs);

      // PROOT
      _downloadProgress = 0.88;
      _statusMessage = 'Descargando PROOT…';
      notifyListeners();
      await _downloadProot(appDir);

      // Verificación final
      bool shOk = await File('$rootfs/bin/sh').exists() &&
                  await File('$rootfs/bin/sh').length() > 0;

      if (!shOk && await File('$rootfs/bin/busybox').exists()) {
        final bb = await File('$rootfs/bin/busybox').length();
        if (bb > 0) {
          _logMsg('Copiando busybox como /bin/sh');
          await File('$rootfs/bin/busybox').copy('$rootfs/bin/sh');
          await _runViaLinker(['chmod', '755', '$rootfs/bin/sh']);
          shOk = true;
        }
      }

      // Para Debian: /bin/dash es el sh
      if (!shOk && await File('$rootfs/bin/dash').exists()) {
        _logMsg('Usando /bin/dash (Debian)');
        await File('$rootfs/bin/dash').copy('$rootfs/bin/sh');
        shOk = true;
      }

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

  // ───── MÉTODO 0: Asset embeeded ─────
  Future<bool> _setupFromAsset(String rootfs) async {
    _logMsg('--- Probando assets embeedidos ---');
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      _logMsg('AssetManifest cargado');

      // Buscar archivos de rootfs
      final hasAlpine = manifest.contains('assets/rootfs.tar.gz');
      final hasDebian = manifest.contains('assets/debian-rootfs.tar.xz');

      if (!hasAlpine && !hasDebian) {
        _logMsg('No hay assets de rootfs embeedidos');
        return false;
      }

      final assetName = hasAlpine ? 'assets/rootfs.tar.gz' : 'assets/debian-rootfs.tar.xz';
      _logMsg('Extrayendo desde asset: $assetName');

      final data = await rootBundle.load(assetName);
      final tempFile = File('${rootfs}_asset');
      await tempFile.writeAsBytes(data.buffer.asUint8List());

      // Extraer con toybox
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) { {
          await Process.run(tb, ['tar', '-xf', tempFile.path, '-C', rootfs])
              .timeout(const Duration(seconds: 120));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) {
            await tempFile.delete();
            return true;
          }
        }
      }

      // Extraer con linker64 + busybox del asset (si Alpine)
      if (hasAlpine) {
        final linker = await _linker;
        if (linker != null) { {
          // Extraer busybox primero
          _logMsg('Usando linker para extraer busybox');
          // No podemos extraer un solo archivo sin tar... usar Dart
          await _extractAssetBusybox(tempFile.path, rootfs);
          final bb = File('$rootfs/bin/busybox');
          if (await bb.exists() && await bb.length() > 0) {
            await _runViaLinker([bb.path, 'tar', '-xf', tempFile.path, '-C', rootfs]);
            await bb.copy('$rootfs/bin/sh');
            if (await File('$rootfs/bin/sh').exists() &&
                await File('$rootfs/bin/sh').length() > 0) {
              await tempFile.delete();
              return true;
            }
          }
        }
      }

      await tempFile.delete();
      return false;
    } catch (e) {
      _logMsg('Asset falló: $e');
      return false;
    }
  }

  Future<void> _extractAssetBusybox(String tarPath, String rootfs) async {
    // Extraer solo busybox del tar.gz usando Dart
    // No implementado - confiamos en toybox del sistema
  }

  // ───── MÉTODO 1: apk.static (con linker64 para saltar noexec) ─────
  Future<bool> _setupWithApkStatic(String appDir, String rootfs) async {
    _logMsg('--- MÉTODO: apk.static ---');
    final linker = await _linker;
    if (linker == null) {
      _logMsg('No hay linker64 disponible en el sistema');
      return false;
    }
    _logMsg('Linker: $linker');

    _statusMessage = 'Descargando apk-tools…';
    notifyListeners();

    final apkBin = '$appDir/apk';
    if (!await File(apkBin).exists()) {
      try {
        await _downloadFile(_apkUrl, apkBin, 0.05, 0.20);
        _logMsg('apk.static descargado');
      } catch (e) {
        _logMsg('ERROR descarga apk.static: $e');
        return false;
      }
    }

    // Verificar con linker (no directo, por noexec)
    try {
      final v = await Process.run(linker, [apkBin, '--version']);
      _logMsg('apk version: ${v.stdout}');
    } catch (e) {
      _logMsg('ERROR: apk no ejecutable via linker: $e');
      return false;
    }

    _downloadProgress = 0.20;
    _statusMessage = 'Configurando repositorios…';
    notifyListeners();

    // Claves RSA
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
    for (final entry in keys.entries) {
      await File('$rootfs/etc/apk/keys/${entry.key}').writeAsString(
        '-----BEGIN PUBLIC KEY-----\n${entry.value}\n-----END PUBLIC KEY-----\n');
    }

    await File('$rootfs/etc/apk/repositories').writeAsString(
      '$_alpineMirror/$_alpineBranch/main\n'
      '$_alpineMirror/$_alpineBranch/community\n');

    // ─── apk --initdb add via linker ───
    _downloadProgress = 0.25;
    _statusMessage = 'Instalando paquetes base…';
    notifyListeners();

    try {
      _logMsg('Ejecutando apk via linker...');
      final result = await Process.run(
        linker, [
          apkBin,
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

      _logMsg('apk exit: ${result.exitCode}');
      if ((result.stderr as String).isNotEmpty)
        _logMsg('apk stderr: ${result.stderr}');

      if (result.exitCode != 0) { return false; }

      // Verificar sh
      if (await File('$rootfs/bin/sh').exists() &&
          await File('$rootfs/bin/sh').length() > 0) return true;

      // Si busybox existe pero sh no, copiar
      if (await File('$rootfs/bin/busybox').exists() &&
          await File('$rootfs/bin/busybox').length() > 0) {
        await File('$rootfs/bin/busybox').copy('$rootfs/bin/sh');
        await _runViaLinker(['chmod', '755', '$rootfs/bin/sh']);
        return true;
      }

      return false;
    } catch (e) {
      _logMsg('EXCEPCIÓN apk: $e');
      return false;
    }
  }

  // ───── MÉTODO 2: Minirootfs tar.gz ─────
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    _logMsg('--- MÉTODO: Minirootfs tar.gz ---');

    _statusMessage = 'Descargando minirootfs…';
    notifyListeners();

    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try {
        await _downloadFile(_minirootfsUrl, tgzPath, 0.30, 0.55);
      } catch (e) {
        _logMsg('ERROR descarga minirootfs: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo…';
    notifyListeners();

    return _extractTar(tgzPath, rootfs);
  }

  // ───── MÉTODO 3: Debian rootfs ─────
  Future<bool> _setupWithDebianRootfs(String appDir, String rootfs) async {
    _logMsg('--- MÉTODO: Debian rootfs ---');

    _statusMessage = 'Descargando Debian rootfs…';
    notifyListeners();

    final xzPath = '$appDir/debian-rootfs.tar.xz';
    if (!await File(xzPath).exists()) {
      try {
        await _downloadFile(_debianRootfsUrl, xzPath, 0.30, 0.55);
      } catch (e) {
        _logMsg('ERROR descarga Debian: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo Debian…';
    notifyListeners();

    // Extraer con toybox (soporta .tar.xz si tiene xz)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) { {
        try {
          await Process.run(tb, ['tar', '-xf', xzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) {
            _logMsg('Debian extraído con $tb');
            return true;
          }
        } catch (e) { _logMsg('$tb falló: $e'); }
      }
    }

    // Fallback: extraer con linker64 + busybox si tenemos
    // Buscar busybox en appDir
    final bb = File('$appDir/bin/busybox');
    final linker = await _linker;
    if (linker != null && await bb.exists() && await bb.length() > 0) {
      try {
        await Process.run(linker, [bb.path, 'tar', '-xf', xzPath, '-C', rootfs])
            .timeout(const Duration(seconds: 180));
        if (await File('$rootfs/bin/sh').exists() &&
            await File('$rootfs/bin/sh').length() > 0) return true;
      } catch (e) { _logMsg('linker+bb falló: $e'); }
    }

    return false;
  }

  // ─── Extraer tar con toybox o linker+busybox ───
  Future<bool> _extractTar(String tarPath, String rootfs) async {
    // toybox
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) { {
        try {
          _logMsg('Extrayendo con $tb');
          await Process.run(tb, ['tar', '-xf', tarPath, '-C', rootfs])
              .timeout(const Duration(seconds: 120));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (e) { _logMsg('$tb falló: $e'); }
      }
    }

    // linker + busybox del directorio de la app
    final appDir = await _appDir;
    final linker = await _linker;
    if (linker != null) { {
      final bb = File('$appDir/bin/busybox');
      if (!await bb.exists()) {
        // Descargar busybox estático alternativo
        // (por ahora no, no tenemos URL fiable)
      } else if (await bb.length() > 0) {
        try {
          _logMsg('Extrayendo con linker+busybox');
          await Process.run(linker, [bb.path, 'tar', '-xf', tarPath, '-C', rootfs])
              .timeout(const Duration(seconds: 120));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (e) { _logMsg('linker+bb falló: $e'); }
      }
    }

    return false;
  }

  // ─── Ejecutar comando via linker (salta noexec) ───
  Future<ProcessResult> _runViaLinker(List<String> args, {Duration? timeout}) async {
    final linker = await _linker;
    if (linker == null) throw Exception('No linker disponible');
    return Process.run(linker, args).timeout(timeout ?? const Duration(seconds: 30));
  }

  // ─── PROOT ───
  Future<void> _downloadProot(String appDir) async {
    final prootPath = '$appDir/proot';
    if (await File(prootPath).exists()) return;

    try {
      _logMsg('Descargando PROOT');
      await _downloadFile(_prootUrl, prootPath, 0.85, 0.95);
      await _runViaLinker(['chmod', '755', prootPath]);
      _logMsg('PROOT OK');
    } catch (e) {
      _logMsg('PROOT no disponible: $e');
    }
  }

  // ─── Chmod ───
  Future<void> _chmodBins(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (await d.exists()) {
        try {
          await for (final entity in d.list()) {
            if (entity is File) {
              try { await _runViaLinker(['chmod', '755', entity.path]); } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }
  }

  // ─── Ejecutar comandos en el entorno Linux ───
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\nPulsa "Setup Linux" primero.\n';
    }

    final rootfs = _rootfsPath!;
    final linker = await _linker;

    // Buscar shell
    String? shellPath;
    for (final p in ['$rootfs/bin/sh', '$rootfs/bin/busybox', '$rootfs/bin/dash']) {
      if (await File(p).exists() && await File(p).length() > 0) { shellPath = p; break; }
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
      } catch (e) { _lastOutput = 'system sh falló: $e\n'; }
    }

    if (shellPath == null) return 'Error: No hay shell disponible.\n';

    try {
      if (linker != null) { {
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
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
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
