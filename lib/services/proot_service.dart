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

  Future<String> getArchitecture() async {
    if (_arch.isNotEmpty) return _arch;
    try {
      final result = await Process.run('uname', ['-m']).timeout(const Duration(seconds: 5));
      final arch = (result.stdout as String).trim();
      if (arch == 'aarch64' || arch == 'arm64') _arch = 'aarch64';
      else if (arch == 'x86_64' || arch == 'amd64') _arch = 'x86_64';
      else if (arch.startsWith('armv')) _arch = 'armv7';
      else _arch = arch;
    } catch (e) { _arch = 'aarch64'; }
    _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/$_alpineVersion/main/$_arch';
    _logMsg('Arquitectura: $_arch');
    return _arch;
  }

  // ═══════════════════════════════════════════════════════
  // runCommand
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final termuxDir = '${await _appDir}/termux';

    try {
      String path = '/system/bin:/system/xbin';
      if (_bionicInstalled) path += ':$termuxDir/bin';
      path += ':$rootfs/usr/local/sbin:$rootfs/usr/local/bin'
              ':$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin';

      final env = <String, String>{
        'PATH': path, 'HOME': '/root', 'TERM': 'xterm-256color',
      };
      if (_bionicInstalled) {
        env['LD_LIBRARY_PATH'] = '$termuxDir/lib';
        env['PREFIX'] = termuxDir;
      }

      _logMsg('cmd: $command');
      final result = await Process.run(
        '/system/bin/sh', ['-c', command],
        environment: env, workingDirectory: rootfs,
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException { _lastOutput = '\n[Timeout]\n'; return _lastOutput; }
      catch (e) { _lastOutput = '\n[Error] $e\n'; return _lastOutput; }
  }

  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) {
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
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        if (st.size > 1000) { _initialized = true; _statusMessage = 'Linux listo'; _logMsg('Rootfs OK'); }
      }
      final termuxDir = '${await _appDir}/termux';
      _bionicInstalled = await File('$termuxDir/bin/sshd').exists() && await File('$termuxDir/bin/bash').exists();
      if (_bionicInstalled) {
        _logMsg('Bionic OK (sshd, bash)');
        if (_initialized) _statusMessage = 'Linux listo + bionic';
      }
      if (!_initialized && !_bionicInstalled) _statusMessage = 'Linux no instalado - pulsa Setup';
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

      // 1: Alpine rootfs
      _statusMessage = 'Extrayendo rootfs Alpine...';
      notifyListeners();
      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo extraer rootfs Alpine');
      _logMsg('Rootfs Alpine OK');
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      // 2: Red
      _downloadProgress = 0.40;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString('127.0.0.1 localhost\n::1 localhost\n');

      // 3: Shell test
      _downloadProgress = 0.50;
      _statusMessage = 'Verificando sistema...';
      notifyListeners();
      try {
        final t = await runCommand('echo "SHELL_OK"', timeout: const Duration(seconds: 10));
        _logMsg('Shell: ${t.trim()}');
      } catch (e) { _logMsg('Shell: $e'); }

      // 4: APKINDEX
      _downloadProgress = 0.55;
      _statusMessage = 'Cargando indice APK...';
      notifyListeners();
      await _refreshApkIndex(rootfs);

      // 5: Bionic tools
      _downloadProgress = 0.60;
      _statusMessage = 'Instalando binarios nativos (nano, sshd, bash)...';
      notifyListeners();
      await _installBionicTools(appDir);

      // 6: Fallback Alpine pkgs if no bionic
      if (!_bionicInstalled) {
        _downloadProgress = 0.85;
        _statusMessage = 'Instalando paquetes Alpine (fallback)...';
        notifyListeners();
        await _installEssentials(rootfs);
      }

      _downloadProgress = 1.0;
      _initialized = true;
      _statusMessage = _bionicInstalled ? 'Linux listo + bionic (nano, sshd OK)' : 'Linux listo (solo toybox)';
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
  // BIONIC TOOLS - Download tarball from GitHub releases
  // ═══════════════════════════════════════════════════════
  Future<void> _installBionicTools(String appDir) async {
    final termuxDir = '$appDir/termux';

    if (await File('$termuxDir/bin/nano').exists() &&
        await File('$termuxDir/bin/sshd').exists() &&
        await File('$termuxDir/bin/bash').exists()) {
      _bionicInstalled = true;
      _logMsg('Bionic bins OK (cached)');
      return;
    }

    final tgzPath = '$appDir/bionic-tools.tar.gz';
    bool downloaded = false;

    // Intentar URLs del release (con validacion de tamano)
    final urls = [
      'https://github.com/txurtxil/LinuxContainer/releases/download/v8.3/bionic-tools.tar.gz',
      'https://github.com/txurtxil/LinuxContainer/releases/latest/download/bionic-tools.tar.gz',
    ];
    for (final url in urls) {
      try {
        _logMsg('Descargando bionic-tools: $url');
        await _downloadFile(url, tgzPath, 0.60, 0.70);
        final size = await File(tgzPath).length();
        _logMsg('bionic-tools tamano: $size bytes');
        if (size < 1000) {
          _logMsg('Muy pequeno (no es un tar.gz valido), reintentando...');
          try { await File(tgzPath).delete(); } catch (_) {}
          continue;
        }
        // Verificar magic bytes gzip
        final data = await File(tgzPath).readAsBytes();
        if (data.length < 2 || data[0] != 0x1F || data[1] != 0x8B) {
          _logMsg('No es gzip valido, reintentando...');
          try { await File(tgzPath).delete(); } catch (_) {}
          continue;
        }
        downloaded = true;
        _logMsg('bionic-tools descargado correctamente');
        break;
      } catch (e) {
        _logMsg('URL fallo: $e');
      }
    }

    // Fallback: intentar construir desde Termux .deb (metodo directo)
    if (!downloaded) {
      _logMsg('Tarball no disponible, intentando bootstrap alternativo...');
      await _installFromTermuxDebs(appDir);
      return;
    }

    // Extraer
    _statusMessage = 'Extrayendo bionic-tools...';
    notifyListeners();
    await Directory(termuxDir).create(recursive: true);

    bool extracted = false;

    // Metodo 1: toybox tar
    for (final tool in ['/system/bin/toybox', '/system/bin/toolbox', '/system/bin/busybox']) {
      if (await File(tool).exists()) {
        try {
          final r = await Process.run(
            tool, ['tar', '-xzf', tgzPath, '-C', termuxDir],
          ).timeout(const Duration(seconds: 60));
          if (r.exitCode == 0) { extracted = true; break; }
        } catch (_) {}
      }
    }

    // Metodo 2: Dart
    if (!extracted) {
      try {
        _logMsg('Usando Dart para extraer...');
        final data = await File(tgzPath).readAsBytes();
        final tarData = GZipDecoder().decodeBytes(data);
        final tar = TarDecoder().decodeBytes(tarData);
        for (final entry in tar) {
          String n = entry.name;
          if (n.startsWith('./')) n = n.substring(2);
          if (n.isEmpty || n == '.') continue;
          if (n.endsWith('/')) { await Directory('$termuxDir/$n').create(recursive: true); continue; }
          final f = File('$termuxDir/$n');
          await f.parent.create(recursive: true);
          if (entry.isFile && entry.content.isNotEmpty) {
            await f.writeAsBytes(entry.content as List<int>);
          }
        }
        extracted = true;
      } catch (e) { _logMsg('Dart error: $e'); }
    }

    try { await File(tgzPath).delete(); } catch (_) {}

    if (!extracted) { _logMsg('No se pudo extraer bionic-tools'); return; }

    // Permisos
    _logMsg('Aplicando permisos...');
    try {
      await for (final f in Directory('$termuxDir/bin').list()) {
        if (f is File) try { await Process.run('chmod', ['+x', f.path]); } catch (_) {}
      }
    } catch (e) { _logMsg('Permisos: $e'); }

    _bionicInstalled = await File('$termuxDir/bin/nano').exists() &&
                       await File('$termuxDir/bin/bash').exists();
    if (_bionicInstalled) {
      _logMsg('Bionic bins OK');
      await _setupBionicSsh(termuxDir);
    } else {
      _logMsg('Bionic bins incompleta');
    }
  }

  /// Fallback: instalar binarios individuales desde URLs directas
  Future<void> _installFromTermuxDebs(String appDir) async {
    final termuxDir = '$appDir/termux';
    await Directory(termuxDir).create(recursive: true);

    // Binarios individuales compilados para Android (bionic)
    // Usamos un enfoque simple: descargar binarios pre-compilados
    final arch = await getArchitecture();
    final ext = arch == 'aarch64' ? 'arm64' : 'arm';

    final binaries = {
      'bash': 'https://github.com/termux/termux-packages/releases/download/bootstrap-archives/bootstrap-$ext.zip',
      // Fallback a URLs directas de binarios
    };

    _logMsg('Bootstrap alternativo no implementado - continuando sin bionic');
  }

  Future<void> _setupBionicSsh(String termuxDir) async {
    _logMsg('Configurando SSH bionic...');
    try {
      await Directory('$termuxDir/etc/ssh').create(recursive: true);
      final config = '''Port 2222
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
Subsystem sftp $termuxDir/libexec/sftp-server
HostKey $termuxDir/etc/ssh/ssh_host_rsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ecdsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ed25519_key
''';
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(config);

      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (!await File(kf).exists()) {
          try {
            await Process.run('$termuxDir/bin/ssh-keygen', ['-t', key, '-f', kf, '-N', '', '-q'],
              environment: {'LD_LIBRARY_PATH': '$termuxDir/lib'},
            ).timeout(const Duration(seconds: 30));
          } catch (e) { _logMsg('Key error: $e'); }
        }
      }
      _logMsg('SSH config OK (puerto 2222)');
    } catch (e) { _logMsg('SSH config error: $e'); }
  }

  // ═══════════════════════════════════════════════════════
  // PUBLIC APK API
  // ═══════════════════════════════════════════════════════
  Future<void> refreshApkIndex() async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    await _refreshApkIndex(rootfs);
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
    if (ver == null) { _logMsg('$pkgName no encontrado'); return false; }
    final ok = await _installApk(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  Future<bool> removeApk(String pkgName) async {
    _installedPkgs.remove(pkgName);
    return true;
  }

  List<Map<String, String>> listInstalledPackages() {
    return _installedPkgs.map((n) => {'name': n, 'version': _apkIndex[n] ?? '?'}).toList();
  }

  String getPackageInfo(String pkgName) {
    final ver = _apkIndex[pkgName];
    if (ver == null) return 'No encontrado: $pkgName';
    return '$pkgName - $ver ${_installedPkgs.contains(pkgName) ? "[instalado]" : "[disponible]"}';
  }

  // ═══════════════════════════════════════════════════════
  // TCP Server (SSH fallback)
  // ═══════════════════════════════════════════════════════
  Future<bool> startTcpCommandServer(int port) async {
    try {
      final server = await HttpServer.bind('0.0.0.0', port);
      _logMsg('TCP Server en puerto $port');
      server.listen((request) async {
        if (request.method == 'POST' && request.uri.path == '/exec') {
          final body = await utf8.decodeStream(request);
          final cmd = jsonDecode(body)['cmd'] as String? ?? '';
          final output = await runCommand(cmd, timeout: const Duration(seconds: 60));
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'output': output}));
          await request.response.close();
        } else { request.response.statusCode = 404; await request.response.close(); }
      });
      return true;
    } catch (e) { _logMsg('TCP error: $e'); return false; }
  }

  // ═══════════════════════════════════════════════════════
  // PRIVATE: Alpine APK
  // ═══════════════════════════════════════════════════════
  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture();
    _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes');
  }

  Future<Map<String, String>> _getApkVersions(String rootfs) async {
    await getArchitecture();
    final idxUrl = '$_alpineMirror/APKINDEX.tar.gz';
    final idxPath = '$rootfs/../APKINDEX.tar.gz';
    if (!await File(idxPath).exists()) {
      try { await _downloadFile(idxUrl, idxPath, 0.80, 0.82); } catch (e) { _logMsg('APKINDEX error: $e'); return {}; }
    }
    try {
      final data = await File(idxPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final idxContent = _extractFileFromTar(tarData, 'APKINDEX');
      if (idxContent == null) return {};
      final result = <String, String>{};
      String cn = '', cv = '';
      for (final line in idxContent.split('\n')) {
        if (line.startsWith('P:')) cn = line.substring(2).trim();
        else if (line.startsWith('V:')) cv = line.substring(2).trim();
        else if (line.isEmpty && cn.isNotEmpty) { result[cn] = cv; cn = ''; cv = ''; }
      }
      return result;
    } catch (e) { _logMsg('APKINDEX parse: $e'); return {}; }
  }

  String? _extractFileFromTar(List<int> tarData, String fileName) {
    int pos = 0;
    while (pos + 512 <= tarData.length) {
      if (tarData[pos] == 0) break;
      final nEnd = tarData.indexOf(0, pos);
      if (nEnd < 0 || nEnd - pos > 100) break;
      final name = String.fromCharCodes(tarData.sublist(pos, nEnd));
      if (name == fileName) {
        final szStr = String.fromCharCodes(tarData.sublist(pos + 124, pos + 136)).split('\x00')[0].trim();
        final sz = int.tryParse(szStr, radix: 8) ?? 0;
        return String.fromCharCodes(tarData.sublist(pos + 512, pos + 512 + sz));
      }
      final szStr = String.fromCharCodes(tarData.sublist(pos + 124, pos + 136)).split('\x00')[0].trim();
      pos += 512 + (((int.tryParse(szStr, radix: 8) ?? 0) + 511) ~/ 512 * 512);
    }
    return null;
  }

  Future<bool> _installApk(String pkg, String ver, String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/$pkg-$ver.apk';
    final apkPath = '$rootfs/../$pkg-$ver.apk';
    try {
      if (!await File(apkPath).exists()) { _logMsg('Descargando: $pkg-$ver'); await _downloadFile(url, apkPath, 0.82, 0.90); }
      final tarData = GZipDecoder().decodeBytes(await File(apkPath).readAsBytes());
      final tar = TarDecoder().decodeBytes(tarData);
      int files = 0;
      for (final entry in tar) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name.isEmpty || name == '.' || name.startsWith('.')) continue;
        if (name.endsWith('/')) { await Directory('$rootfs/$name').create(recursive: true); files++; continue; }
        if (name.contains('.pre-install') || name.contains('.post-install') || name.contains('.trigger')) continue;
        final target = File('$rootfs/$name');
        await target.parent.create(recursive: true);
        if (entry.isSymbolicLink && (entry.symbolicLink ?? '').isNotEmpty) {
          final lt = entry.symbolicLink!;
          if (lt.startsWith('/')) {
            final rt = File('$rootfs$lt');
            if (await rt.exists() && await rt.length() > 0) {
              try { if (await Link(target.path).exists()) await Link(target.path).delete(); await target.writeAsBytes(await rt.readAsBytes()); files++; } catch (_) {}
            }
          }
          continue;
        }
        if (entry.isFile && entry.content.isNotEmpty) {
          await target.writeAsBytes(entry.content as List<int>);
          final mode = entry.mode;
          if (mode != null && (mode & 0x49) != 0) { try { await Process.run('chmod', ['+x', target.path]); } catch (_) {} }
          files++;
        }
      }
      _logMsg('$pkg-$ver: $files archivos');
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) { _logMsg('Error $pkg: $e'); return false; }
  }

  Future<void> _installEssentials(String rootfs) async {
    if (_apkIndex.isEmpty) _apkIndex = await _getApkVersions(rootfs);
    for (final pkg in ['openssh-server', 'openssh-keygen', 'bash', 'nano']) {
      final ver = _apkIndex[pkg];
      if (ver == null) continue;
      if (await _installApk(pkg, ver, rootfs)) _installedPkgs.add(pkg);
    }
  }

  // ═══════════════════════════════════════════════════════
  // HELPERS
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
      if (!(await rootBundle.loadString('AssetManifest.json')).contains('assets/rootfs.tar.gz')) return false;
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      await File('${await _appDir}/cached_rootfs.tar.gz').writeAsBytes(data.buffer.asUint8List());
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try {
            final r = await Process.run(tb, ['tar', '-xzf', '${await _appDir}/cached_rootfs.tar.gz', '-C', rootfs]).timeout(const Duration(seconds: 180));
            if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0) return true;
          } catch (_) {}
        }
      }
      return _extractTarDart('${await _appDir}/cached_rootfs.tar.gz', rootfs);
    } catch (e) { return false; }
  }

  Future<bool> _extractTarDart(String tgz, String rootfs) async {
    try {
      for (final entry in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(tgz).readAsBytes()))) {
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
          final r = await Process.run(tb, ['tar', '-xzf', tgz, '-C', rootfs]).timeout(const Duration(seconds: 180));
          if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (_) {}
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
        await for (final e in Directory('$rootfs$dir').list(followLinks: false)) {
          if (e is File && await e.length() == 0 && d != null) { await e.writeAsBytes(d); n++; }
        }
      } catch (_) {}
    }
    if (d != null) {
      final sh = File('$rootfs/bin/sh');
      if (!await sh.exists() || await sh.length() == 0) { try { await sh.writeAsBytes(d); n++; } catch (_) {} }
    }
    _logMsg('Hardlinks: $n');
  }

  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    int n = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      try {
        await for (final e in Directory('$rootfs$dir').list(followLinks: false)) {
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
    _apkIndex = {}; _installedPkgs.clear(); _bionicInstalled = false;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
