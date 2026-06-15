import 'dart:async';
import 'dart:convert';
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
  Map<String, String> _apkIndex = {};
  final Set<String> _installedPkgs = {};
  String _arch = '';
  bool _bionicInstalled = false;

  List<String> get log => List.unmodifiable(_log);
  String get logText => _log.join('\n');
  void _logMsg(String msg) {
    _log.add('[${DateTime.now().toString().substring(11, 19)}] $msg');
    debugPrint('Proot: $msg');
  }

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;
  String? get rootfsPath => _rootfsPath;
  Map<String, String> get apkIndex => Map.unmodifiable(_apkIndex);
  Set<String> get installedPackages => Set.unmodifiable(_installedPkgs);
  bool get hasBionic => _bionicInstalled;

  String? _rootfsPath;
  String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main';
  static const String _alpineVersion = 'v3.24';

  Future<String> get _appDir async {
    return '${(await getApplicationDocumentsDirectory()).path}/linux_container';
  }

  /// Detect device architecture
  Future<String> getArchitecture() async {
    if (_arch.isNotEmpty) return _arch;
    try {
      final result = await Process.run('uname', ['-m']).timeout(const Duration(seconds: 5));
      final arch = (result.stdout as String).trim();
      if (arch == 'aarch64' || arch == 'arm64') _arch = 'aarch64';
      else if (arch == 'x86_64' || arch == 'amd64') _arch = 'x86_64';
      else if (arch.startsWith('armv')) _arch = 'armv7';
      else _arch = arch;
    } catch (e) {
      _arch = 'aarch64';
    }
    _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/$_alpineVersion/main/$_arch';
    _logMsg('Arquitectura: $_arch');
    return _arch;
  }

  Future<String> get _termuxArch async {
    final a = await getArchitecture();
    if (a == 'aarch64') return 'aarch64';
    if (a == 'armv7') return 'arm';
    if (a == 'x86_64') return 'x86_64';
    return 'aarch64';
  }

  // ═══════════════════════════════════════════════════════
  // runCommand: system shell (toybox) con PATH rootfs + bionic
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final termuxDir = '${await _appDir}/termux';

    try {
      String path = '/system/bin:/system/xbin';
      if (_bionicInstalled) {
        path += ':$termuxDir/bin';
      }
      path += ':$rootfs/usr/local/sbin:$rootfs/usr/local/bin'
              ':$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin';

      final env = <String, String>{
        'PATH': path,
        'HOME': '/root',
        'TERM': 'xterm-256color',
      };
      if (_bionicInstalled) {
        env['LD_LIBRARY_PATH'] = '$termuxDir/lib';
        env['PREFIX'] = termuxDir;
      }

      _logMsg('cmd: $command');
      final result = await Process.run(
        '/system/bin/sh', ['-c', command],
        environment: env,
        workingDirectory: rootfs,
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException { _lastOutput = '\n[Timeout]\n'; return _lastOutput; }
      catch (e) { _lastOutput = '\n[Error] $e\n'; return _lastOutput; }
  }

  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    return runCommand(command, timeout: timeout);
  }

  // ═══════════════════════════════════════════════════════
  // checkEnvironment
  // ═══════════════════════════════════════════════════════
  Future<bool> checkEnvironment() async {
    _log.clear();
    try {
      await getArchitecture();
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;

      // Check Alpine rootfs
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        if (st.size > 1000) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          _logMsg('Rootfs OK');
        }
      }

      // Check bionic binaries
      final termuxDir = '${await _appDir}/termux';
      _bionicInstalled = await File('$termuxDir/bin/sshd').exists() &&
                         await File('$termuxDir/bin/bash').exists();

      if (_bionicInstalled) {
        _logMsg('Bionic binaries OK (sshd, bash)');
        if (_statusMessage == 'Linux listo') {
          _statusMessage = 'Linux listo + bionic';
        }
      }

      if (!_initialized && !_bionicInstalled) {
        _statusMessage = 'Linux no instalado - pulsa Setup';
      }
      notifyListeners();
      return _initialized;
    } catch (e) { _logMsg('Error: $e'); return false; }
  }

  // ═══════════════════════════════════════════════════════
  // setupEnvironment
  // ═══════════════════════════════════════════════════════
  Future<void> setupEnvironment() async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _statusMessage = 'Iniciando...';
    _lastOutput = '';
    _log.clear();
    _logMsg('=== INICIO SETUP ===');
    notifyListeners();

    try {
      await getArchitecture();
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
      _rootfsPath = rootfs;
      await Directory(appDir).create(recursive: true);
      await Directory(rootfs).create(recursive: true);

      // Etapa 1: Alpine rootfs
      _statusMessage = 'Extrayendo rootfs Alpine...';
      notifyListeners();
      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo extraer rootfs Alpine');
      _logMsg('Rootfs Alpine OK');

      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      _downloadProgress = 0.50;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // Verificar shell
      _downloadProgress = 0.60;
      _statusMessage = 'Verificando sistema...';
      notifyListeners();
      try {
        final test = await runCommand('echo "SHELL_OK"', timeout: const Duration(seconds: 10));
        _logMsg('Shell: ${test.trim()}');
      } catch (e) { _logMsg('Shell: $e'); }

      // Etapa 2: Bionic binaries (TERMUX bootstrap)
      _downloadProgress = 0.65;
      _statusMessage = 'Instalando binarios bionic (sshd, bash)...';
      notifyListeners();
      await _installBionicBinaries(appDir);

      // Etapa 3: Cargar indice APK
      if (!_bionicInstalled) {
        _downloadProgress = 0.80;
        _statusMessage = 'Cargando indice de paquetes...';
        notifyListeners();
        await _refreshApkIndex(rootfs);
      }

      // Etapa 4: Paquetes esenciales
      _downloadProgress = 0.85;
      _statusMessage = 'Instalando paquetes esenciales...';
      notifyListeners();
      if (!_bionicInstalled) {
        await _installEssentials(rootfs);
      }

      _downloadProgress = 1.0;
      _initialized = true;
      if (_bionicInstalled) {
        _statusMessage = 'Linux listo + bionic (sshd, bash OK)';
      } else {
        _statusMessage = 'Linux listo (sin bionic)';
      }
      _logMsg('=== FIN SETUP ===');
    } catch (e) {
      _logMsg('EXCEPCION: $e');
      _statusMessage = 'Error: $e';
      _initialized = false;
    } finally {
      _isDownloading = false;
      _lastOutput = logText;
      notifyListeners();
    }
  }

  // ═══════════════════════════════════════════════════════
  // BIONIC BINARIES (Termux bootstrap)
  // ═══════════════════════════════════════════════════════
  Future<void> _installBionicBinaries(String appDir) async {
    final termuxDir = '$appDir/termux';

    // Check if already installed
    if (await File('$termuxDir/bin/sshd').exists() &&
        await File('$termuxDir/bin/bash').exists()) {
      _bionicInstalled = true;
      _logMsg('Bionic bins: OK (cached)');
      return;
    }

    final tArch = await _termuxArch;
    final zipUrl = 'https://github.com/termux/termux-packages/releases/download/'
                   'bootstrap-archives/bootstrap-$tArch.zip';
    final zipPath = '$appDir/bootstrap.zip';

    _logMsg('Descargando bootstrap Termux ($tArch)...');
    try {
      await _downloadFile(zipUrl, zipPath, 0.65, 0.75);
    } catch (e) {
      _logMsg('Error descargando bootstrap: $e');
      _statusMessage = 'Bootstrap no disponible, continuando sin bionic';
      notifyListeners();
      return;
    }

    _statusMessage = 'Extrayendo bootstrap Termux...';
    notifyListeners();
    _logMsg('Extrayendo bootstrap...');

    try {
      await Directory(termuxDir).create(recursive: true);

      // Intentar con toybox unzip
      bool extracted = false;
      for (final tool in ['/system/bin/toybox', '/system/bin/busybox']) {
        if (await File(tool).exists()) {
          try {
            final r = await Process.run(
              tool, ['unzip', '-o', zipPath, '-d', termuxDir],
            ).timeout(const Duration(seconds: 120));
            if (r.exitCode == 0) { extracted = true; break; }
          } catch (_) {}
        }
      }

      // Fallback: Dart ZipDecoder
      if (!extracted) {
        _logMsg('Usando ZipDecoder Dart...');
        final data = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(data);
        for (final entry in archive) {
          final name = entry.name;
          if (name.endsWith('/')) {
            await Directory('$termuxDir/$name').create(recursive: true);
          } else if (entry.isFile) {
            final f = File('$termuxDir/$name');
            await f.parent.create(recursive: true);
            await f.writeAsBytes(entry.content as List<int>);
          }
        }
        extracted = true;
      }

      if (!extracted) {
        _logMsg('No se pudo extraer bootstrap');
        return;
      }

      // Verificar archivos esenciales
      _bionicInstalled = await File('$termuxDir/bin/sshd').exists() &&
                        await File('$termuxDir/bin/bash').exists() &&
                        await File('$termuxDir/bin/ssh-keygen').exists();

      if (_bionicInstalled) {
        _logMsg('OK: sshd, ssh-keygen, bash disponibles');
        // Configurar SSH
        await _setupBionicSsh(appDir, termuxDir);
      } else {
        _logMsg('Algunos binarios faltan en bootstrap');
        // Listar lo que hay
        for (final d in ['/bin', '/lib']) {
          try {
            final files = await Directory('$termuxDir$d').list().toList();
            _logMsg('$d: ${files.length} archivos');
          } catch (_) {}
        }
      }

      // Limpiar zip
      try { await File(zipPath).delete(); } catch (_) {}
    } catch (e) {
      _logMsg('Error extrayendo bootstrap: $e');
    }
  }

  Future<void> _setupBionicSsh(String appDir, String termuxDir) async {
    _logMsg('Configurando SSH bionic...');

    // Crear directorio de configuracion SSH
    await Directory('$termuxDir/etc/ssh').create(recursive: true);

    // Crear sshd_config
    final sshdConfig = '''# Generado por Linux Container App
Port 2222
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp $termuxDir/libexec/sftp-server
HostKey $termuxDir/etc/ssh/ssh_host_rsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ecdsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ed25519_key
''';
    try {
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(sshdConfig);
    } catch (e) {
      _logMsg('Error config: $e');
    }

    // Generar host keys si no existen
    for (final key in ['ssh_host_rsa_key', 'ssh_host_ecdsa_key', 'ssh_host_ed25519_key']) {
      if (!await File('$termuxDir/etc/ssh/$key').exists()) {
        try {
          _logMsg('Generando $key...');
          await Process.run('/system/bin/sh', ['-c'],
            environment: {
              'PATH': '$termuxDir/bin:/system/bin',
              'LD_LIBRARY_PATH': '$termuxDir/lib',
              'HOME': '/root',
            },
          );
          await Process.run(
            '$termuxDir/bin/ssh-keygen', ['-t', key.contains('rsa') ? 'rsa' :
                key.contains('ecdsa') ? 'ecdsa' : 'ed25519',
                '-f', '$termuxDir/etc/ssh/$key', '-N', '', '-q'],
            environment: {
              'LD_LIBRARY_PATH': '$termuxDir/lib',
              'HOME': '/data/data/com.micloj.linux_container_app/files',
            },
          ).timeout(const Duration(seconds: 30));
        } catch (e) {
          _logMsg('Error generando $key');
        }
      }
    }
    _logMsg('SSH bionic configurado');
  }

  // ═══════════════════════════════════════════════════════
  // PUBLIC APK MANAGEMENT API
  // ═══════════════════════════════════════════════════════
  Future<void> refreshApkIndex() async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    await _refreshApkIndex(rootfs);
  }

  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture();
    _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes');
  }

  List<Map<String, String>> searchPackages(String query, {int limit = 50}) {
    final results = <Map<String, String>>[];
    final q = query.toLowerCase();
    for (final entry in _apkIndex.entries) {
      if (entry.key.toLowerCase().contains(q)) {
        results.add({'name': entry.key, 'version': entry.value});
        if (results.length >= limit) break;
      }
    }
    return results;
  }

  Future<bool> installApk(String pkgName) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final ver = _apkIndex[pkgName];
    if (ver == null) { _logMsg('$pkgName: no encontrado en APKINDEX'); return false; }
    final ok = await _installApk(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  Future<bool> removeApk(String pkgName) async {
    _installedPkgs.remove(pkgName);
    _logMsg('$pkgName: marcado como eliminado');
    return true;
  }

  List<Map<String, String>> listInstalledPackages() {
    return _installedPkgs.map((name) => {
      'name': name,
      'version': _apkIndex[name] ?? '?',
    }).toList();
  }

  String getPackageInfo(String pkgName) {
    final ver = _apkIndex[pkgName];
    if (ver == null) return 'Paquete no encontrado: $pkgName';
    final installed = _installedPkgs.contains(pkgName);
    return '$pkgName - $ver ${installed ? "[instalado]" : "[disponible]"}';
  }

  // ═══════════════════════════════════════════════════════
  // TCP Server (SSH alternative)
  // ═══════════════════════════════════════════════════════
  Future<bool> startTcpCommandServer(int port) async {
    try {
      final server = await HttpServer.bind('0.0.0.0', port);
      _logMsg('TCP Server escuchando en puerto $port');
      server.listen((request) async {
        if (request.method == 'POST' && request.uri.path == '/exec') {
          final body = await utf8.decodeStream(request);
          final cmd = jsonDecode(body)['cmd'] as String? ?? '';
          final output = await runCommand(cmd, timeout: const Duration(seconds: 60));
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'output': output}));
          await request.response.close();
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
      return true;
    } catch (e) {
      _logMsg('TCP Server error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════
  // PRIVATE: Alpine APK Management
  // ═══════════════════════════════════════════════════════
  Future<Map<String, String>> _getApkVersions(String rootfs) async {
    await getArchitecture();
    final idxUrl = '$_alpineMirror/APKINDEX.tar.gz';
    final idxPath = '$rootfs/../APKINDEX.tar.gz';

    if (!await File(idxPath).exists()) {
      try {
        await _downloadFile(idxUrl, idxPath, 0.80, 0.82);
      } catch (e) {
        _logMsg('Error APKINDEX: $e');
        return {};
      }
    }

    try {
      final data = await File(idxPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final idxContent = _extractFileFromTar(tarData, 'APKINDEX');
      if (idxContent == null) { _logMsg('APKINDEX no encontrado en tar'); return {}; }

      final result = <String, String>{};
      String cn = '', cv = '';
      for (final line in idxContent.split('\n')) {
        if (line.startsWith('P:')) cn = line.substring(2).trim();
        else if (line.startsWith('V:')) cv = line.substring(2).trim();
        else if (line.isEmpty && cn.isNotEmpty) {
          result[cn] = cv;
          cn = ''; cv = '';
        }
      }
      return result;
    } catch (e) {
      _logMsg('Parse APKINDEX: $e');
      return {};
    }
  }

  String? _extractFileFromTar(List<int> tarData, String fileName) {
    int pos = 0;
    while (pos + 512 <= tarData.length) {
      if (tarData[pos] == 0) break;
      final nameEnd = tarData.indexOf(0, pos);
      if (nameEnd < 0 || nameEnd - pos > 100) break;
      final name = String.fromCharCodes(tarData.sublist(pos, nameEnd));
      if (name == fileName) {
        final szStr = String.fromCharCodes(tarData.sublist(pos + 124, pos + 136))
            .split('\x00')[0].trim();
        final sz = int.tryParse(szStr, radix: 8) ?? 0;
        return String.fromCharCodes(tarData.sublist(pos + 512, pos + 512 + sz));
      }
      final szStr = String.fromCharCodes(tarData.sublist(pos + 124, pos + 136))
          .split('\x00')[0].trim();
      final padded = ((int.tryParse(szStr, radix: 8) ?? 0) + 511) ~/ 512 * 512;
      pos += 512 + padded;
    }
    return null;
  }

  Future<bool> _installApk(String pkg, String ver, String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/$pkg-$ver.apk';
    final apkPath = '$rootfs/../$pkg-$ver.apk';

    try {
      if (!await File(apkPath).exists()) {
        _logMsg('Descargando: $pkg-$ver');
        await _downloadFile(url, apkPath, 0.82, 0.90);
      }

      final data = await File(apkPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final tar = TarDecoder().decodeBytes(tarData);

      int files = 0;
      for (final entry in tar) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name.isEmpty || name == '.' || name.startsWith('.')) continue;
        if (name.endsWith('/')) {
          await Directory('$rootfs/$name').create(recursive: true);
          files++; continue;
        }
        if (name.contains('.pre-install') || name.contains('.post-install') ||
            name.contains('.trigger')) continue;

        final target = File('$rootfs/$name');
        await target.parent.create(recursive: true);

        if (entry.isSymbolicLink && (entry.symbolicLink ?? '').isNotEmpty) {
          final linkTarget = entry.symbolicLink!;
          if (linkTarget.startsWith('/')) {
            final realTarget = File('$rootfs$linkTarget');
            if (await realTarget.exists() && await realTarget.length() > 0) {
              try {
                if (await Link(target.path).exists()) await Link(target.path).delete();
                await target.writeAsBytes(await realTarget.readAsBytes());
                files++;
              } catch (_) {}
            }
          }
          continue;
        }

        if (entry.isFile && entry.content.isNotEmpty) {
          await target.writeAsBytes(entry.content as List<int>);
          final mode = entry.mode;
          if (mode != null && (mode & 0x49) != 0) {
            try { await Process.run('chmod', ['+x', target.path]); } catch (_) {}
          }
          files++;
        }
      }
      _logMsg('$pkg-$ver: $files archivos extraidos');
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) {
      _logMsg('Error $pkg: $e');
      return false;
    }
  }

  Future<void> _installEssentials(String rootfs) async {
    _logMsg('=== Instalando paquetes esenciales (Dart) ===');
    if (_apkIndex.isEmpty) {
      _apkIndex = await _getApkVersions(rootfs);
    }

    final packages = [
      'openssh-server', 'openssh-keygen', 'openssh-sftp-server',
      'curl', 'wget', 'bash', 'ca-certificates', 'sudo', 'nano'
    ];

    int installed = 0, failed = 0;
    for (final pkg in packages) {
      final ver = _apkIndex[pkg];
      if (ver == null) { _logMsg('$pkg: no encontrado en repositorio'); continue; }
      _statusMessage = 'Instalando $pkg...';
      notifyListeners();
      if (await _installApk(pkg, ver, rootfs)) {
        _installedPkgs.add(pkg);
        installed++;
      } else { failed++; }
    }

    _logMsg('Paquetes: $installed instalados, $failed fallos');
    _statusMessage = 'Paquetes esenciales instalados';
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════
  // Funciones auxiliares
  // ═══════════════════════════════════════════════════════
  Future<void> _downloadFile(String url, String path, double sw, double ew) async {
    final c = HttpClient();
    try {
      _logMsg('Download: $url');
      final req = await c.getUrl(Uri.parse(url));
      final resp = await req.close();
      _logMsg('HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final total = resp.contentLength;
      int recv = 0;
      final sink = File(path).openWrite();
      await for (final chunk in resp) {
        sink.add(chunk); recv += chunk.length;
        if (total > 0) {
          _downloadProgress = sw + (recv / total) * (ew - sw);
          if (recv % (1024 * 256) < chunk.length) notifyListeners();
        }
      }
      await sink.flush(); await sink.close();
      _logMsg('OK: $recv bytes');
    } finally { c.close(); }
  }

  Future<bool> _setupFromAsset(String rootfs) async {
    try {
      if (!(await rootBundle.loadString('AssetManifest.json'))
          .contains('assets/rootfs.tar.gz')) return false;
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      await File('${await _appDir}/cached_rootfs.tar.gz')
          .writeAsBytes(data.buffer.asUint8List());
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try {
            final r = await Process.run(
              tb, ['tar', '-xzf', '${await _appDir}/cached_rootfs.tar.gz', '-C', rootfs])
                .timeout(const Duration(seconds: 180));
            if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
                await File('$rootfs/bin/sh').length() > 0) return true;
          } catch (e) {}
        }
      }
      return _extractTarDart('${await _appDir}/cached_rootfs.tar.gz', rootfs);
    } catch (e) { return false; }
  }

  Future<bool> _extractTarDart(String tgz, String rootfs) async {
    try {
      for (final entry in TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(await File(tgz).readAsBytes()))) {
        String n = entry.name;
        if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        if (n.endsWith('/')) { await Directory('$rootfs/$n').create(recursive: true); continue; }
        await Directory('$rootfs/$n').parent.create(recursive: true);
        if (entry.isSymbolicLink && (entry.symbolicLink ?? '').startsWith('/')) {
          try {
            final r = File('$rootfs${entry.symbolicLink}');
            if (await r.exists() && await r.length() > 0) {
              if (await Link('$rootfs/$n').exists()) await Link('$rootfs/$n').delete();
              await File('$rootfs/$n').writeAsBytes(await r.readAsBytes());
            }
          } catch (_) {}
          continue;
        }
        if (entry.isFile && entry.content.isNotEmpty) {
          await File('$rootfs/$n').writeAsBytes(entry.content);
        }
      }
      return true;
    } catch (e) { return false; }
  }

  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    final tgz = '$appDir/rootfs.tar.gz';
    if (!await File(tgz).exists()) return false;
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          final r = await Process.run(
            tb, ['tar', '-xzf', tgz, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (e) {}
      }
    }
    return _extractTarDart(tgz, rootfs);
  }

  Future<void> _fixHardlinks(String rootfs) async {
    int n = 0;
    final bb = File('$rootfs/bin/busybox');
    List<int>? d;
    if (await bb.exists() && await bb.length() > 0) d = await bb.readAsBytes();
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
      try {
        final dd = Directory('$rootfs$dir');
        if (!await dd.exists()) continue;
        await for (final e in dd.list(followLinks: false)) {
          if (e is File && await e.length() == 0 && d != null) {
            await e.writeAsBytes(d); n++;
          }
        }
      } catch (_) {}
    }
    if (d != null) {
      final sh = File('$rootfs/bin/sh');
      if (!await sh.exists() || await sh.length() == 0) {
        try { await sh.writeAsBytes(d); n++; } catch (_) {}
      }
    }
    _logMsg('Hardlinks: $n');
  }

  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    int n = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(followLinks: false)) {
          if (e is Link) {
            try {
              final t = await e.target();
              if (t.startsWith('/')) {
                final r = File('$rootfs$t');
                if (await r.exists() && await r.length() > 0) {
                  try { await e.delete(); } catch (_) {}
                  await File(e.path).writeAsBytes(await r.readAsBytes()); n++;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    _logMsg('Symlinks: $n');
  }

  Future<void> resetEnvironment() async {
    final d = await _appDir;
    try { await Directory(d).delete(recursive: true); } catch (_) {}
    _initialized = false; _rootfsPath = null;
    _apkIndex = {}; _installedPkgs.clear();
    _bionicInstalled = false;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
