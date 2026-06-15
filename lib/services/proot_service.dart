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
      _arch = 'aarch64'; // default
    }
    _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/$_alpineVersion/main/$_arch';
    _logMsg('Arquitectura: $_arch');
    return _arch;
  }

  // ═══════════════════════════════════════════════════════
  // runCommand: system shell (toybox) con PATH rootfs
  // Usa /system/bin/sh que permite execve desde /system/bin
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';

    try {
      _logMsg('cmd: $command');
      final result = await Process.run(
        '/system/bin/sh', ['-c', command],
        environment: {
          'PATH': '/system/bin:/system/xbin:' +
                  '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:' +
                  '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin',
          'HOME': '/root',
          'TERM': 'xterm-256color',
        },
        workingDirectory: rootfs,
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException { _lastOutput = '\n[Timeout]\n'; return _lastOutput; }
      catch (e) { _lastOutput = '\n[Error] $e\n'; return _lastOutput; }
  }

  // ═══════════════════════════════════════════════════════
  // runShell: interactiva
  // ═══════════════════════════════════════════════════════
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
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        if (st.size > 1000) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          _logMsg('Rootfs OK, system shell disponible');
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Linux no instalado - pulsa Setup';
      notifyListeners();
      return false;
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

      // 1: Alpine rootfs desde asset
      _statusMessage = 'Extrayendo rootfs Alpine...';
      notifyListeners();
      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo extraer rootfs');
      _logMsg('Rootfs Alpine OK');

      // 2: Reparar hardlinks y symlinks
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      // 3: Configurar red
      _downloadProgress = 0.50;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // 4: Verificar shell
      _downloadProgress = 0.70;
      _statusMessage = 'Verificando sistema...';
      notifyListeners();
      try {
        final test = await runCommand('echo "SHELL_OK"',
            timeout: const Duration(seconds: 10));
        _logMsg('Shell: ${test.trim()}');
      } catch (e) { _logMsg('Shell: $e'); }

      // 5: Cargar indice APK
      _downloadProgress = 0.80;
      _statusMessage = 'Cargando indice de paquetes...';
      notifyListeners();
      await _refreshApkIndex(rootfs);

      // 6: Instalar paquetes esenciales via Dart
      _downloadProgress = 0.85;
      _statusMessage = 'Instalando paquetes esenciales...';
      notifyListeners();
      await _installEssentials(rootfs);

      _downloadProgress = 1.0;
      _initialized = true;
      _statusMessage = 'Linux listo - Todo instalado';
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
  // PUBLIC APK MANAGEMENT API
  // ═══════════════════════════════════════════════════════

  /// Refresca el indice APKINDEX desde el mirror Alpine
  Future<void> refreshApkIndex() async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    await _refreshApkIndex(rootfs);
  }

  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture();
    _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes');
  }

  /// Busca paquetes por nombre
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

  /// Instala un paquete Alpine via Dart (extrae .apk al rootfs)
  Future<bool> installApk(String pkgName) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final ver = _apkIndex[pkgName];
    if (ver == null) { _logMsg('$pkgName: no encontrado en APKINDEX'); return false; }
    final ok = await _installApk(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  /// Elimina un paquete instalado
  Future<bool> removeApk(String pkgName) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    // Intentar eliminar archivos conocidos (no tenemos DB de archivos)
    // Por ahora solo marcamos como no instalado
    _installedPkgs.remove(pkgName);
    _logMsg('$pkgName: marcado como eliminado');
    return true;
  }

  /// Lista paquetes instalados
  List<Map<String, String>> listInstalledPackages() {
    return _installedPkgs.map((name) => {
      'name': name,
      'version': _apkIndex[name] ?? '?',
    }).toList();
  }

  /// Obtiene informacion de un paquete
  String getPackageInfo(String pkgName) {
    final ver = _apkIndex[pkgName];
    if (ver == null) return 'Paquete no encontrado: $pkgName';
    final installed = _installedPkgs.contains(pkgName);
    return '$pkgName - $ver ${installed ? "[instalado]" : "[disponible]"}';
  }

  // ═══════════════════════════════════════════════════════
  // PROOT ALTERNATIVE: Direct command execution
  // ═══════════════════════════════════════════════════════
  /// Inicia un servidor TCP simple para acceso remoto (alternativa a SSH)
  /// Usa Dart's HttpServer para crear un endpoint de comandos
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

  /// Parsea APKINDEX.tar.gz y devuelve {nombre: version}
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

  /// Extrae un archivo de datos tar raw
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

  /// Descarga e instala un .apk (gzip+tar) al rootfs
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
        // Saltar scripts de instalacion
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
          } else {
            try {
              if (await Link(target.path).exists()) await Link(target.path).delete();
              await target.writeAsBytes(utf8.encode(linkTarget));
              files++;
            } catch (_) {}
          }
          continue;
        }

        if (entry.isFile && entry.content.isNotEmpty) {
          await target.writeAsBytes(entry.content as List<int>);
          // Aplicar permisos de ejecucion si corresponde
          final mode = entry.mode;
          if (mode != null && (mode & 0x49) != 0) { // any exec bit
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

  /// Instala paquetes esenciales
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
        // Symlink absolutos: copiar contenido
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
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
