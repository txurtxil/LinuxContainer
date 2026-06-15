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
    debugPrint('Proot: $msg');
  }

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;
  String? get rootfsPath => _rootfsPath;
  String? get staticBusyboxPath => _staticBusyboxPath;
  String? get apkStaticPath => _apkStaticPath;

  String? _rootfsPath;
  String? _staticBusyboxPath;
  String? _apkStaticPath;

  static const String _mirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64';

  Future<String> get _appDir async {
    return '${(await getApplicationDocumentsDirectory()).path}/linux_container';
  }

  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  // ─── checkEnvironment ───
  Future<bool> checkEnvironment() async {
    _log.clear();
    try {
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      
      // Buscar busybox.static en rootfs (extraido del .apk Alpine)
      String? findBB() {
        for (final d in ['/bin', '/sbin', '/usr/bin', '/usr/local/bin']) {
          final f = File('$rootfs$d/busybox.static');
          if (f.existsSync() && f.lengthSync() > 100000) return f.path;
        }
        return null;
      }
      
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        final bbPath = findBB();
        if (st.size > 1000 && bbPath != null) {
          _initialized = true;
          _staticBusyboxPath = bbPath;
          // Buscar apk.static
          for (final d in ['/sbin', '/bin', '/usr/bin', '/usr/local/bin']) {
            final a = File('$rootfs$d/apk.static');
            if (await a.exists() && await a.length() > 100000) {
              _apkStaticPath = a.path;
              break;
            }
          }
          _statusMessage = 'Linux listo';
          _logMsg('Rootfs OK, static binaries OK');
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Linux no instalado - pulsa Setup';
      notifyListeners();
      return false;
    } catch (e) {
      _logMsg('Error checkEnvironment: $e');
      _statusMessage = 'Error: $e';
      notifyListeners();
      return false;
    }
  }

  // ─── Resolver version de paquete desde APKINDEX ───
  Future<String> _resolveVersion(String pkgName, String rootfs) async {
    final idxPath = '$rootfs/../APKINDEX.tar.gz';
    if (!await File(idxPath).exists()) {
      try {
        final url = '$_mirror/APKINDEX.tar.gz';
        final c = HttpClient();
        try {
          final req = await c.getUrl(Uri.parse(url));
          final resp = await req.close();
          if (resp.statusCode == 200) {
            final sink = File(idxPath).openWrite();
            await for (final chunk in resp) sink.add(chunk);
            await sink.close();
          } else throw Exception('HTTP ${resp.statusCode}');
        } finally { c.close(); }
      } catch (e) { return ''; }
    }

    try {
      final data = await File(idxPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      int pos = 0;
      while (pos + 512 <= tarData.length) {
        if (tarData[pos] == 0) break;
        final nameEnd = tarData.indexOf(0, pos);
        if (nameEnd < 0 || nameEnd - pos > 100) break;
        final name = String.fromCharCodes(tarData.sublist(pos, nameEnd));
        if (name == 'APKINDEX') {
          final sizeBytes = tarData.sublist(pos + 124, pos + 136);
          final sizeStr = String.fromCharCodes(sizeBytes).split('\x00')[0].trim();
          final size = int.tryParse(sizeStr, radix: 8) ?? 0;
          final content = tarData.sublist(pos + 512, pos + 512 + size);
          final lines = String.fromCharCodes(content).split('\n');
          String cn = '', cv = '';
          for (final line in lines) {
            if (line.startsWith('P:')) cn = line.substring(2).trim();
            else if (line.startsWith('V:')) cv = line.substring(2).trim();
            else if (line.isEmpty && cn == pkgName) return cv;
            else if (line.isEmpty) { cn = ''; cv = ''; }
          }
        }
        final sBytes = tarData.sublist(pos + 124, pos + 136);
        final sStr = String.fromCharCodes(sBytes).split('\x00')[0].trim();
        final sz = int.tryParse(sStr, radix: 8) ?? 0;
        pos += 512 + ((sz + 511) ~/ 512) * 512;
      }
    } catch (e) { _logMsg('APKINDEX: $e'); }
    return '';
  }

  // ─── Descargar y extraer .apk (gzip+tar) ───
  Future<String?> _downloadAndExtract(String pkgName, String version,
                                        String rootfs, String searchBin) async {
    final apkUrl = '$_mirror/$pkgName-$version.apk';
    final apkPath = '$rootfs/../$pkgName.apk';

    try {
      if (!await File(apkPath).exists()) {
        _logMsg('Descargando: $pkgName-$version');
        final c = HttpClient();
        try {
          final req = await c.getUrl(Uri.parse(apkUrl));
          final resp = await req.close();
          if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
          final sink = File(apkPath).openWrite();
          await for (final chunk in resp) sink.add(chunk);
          await sink.close();
        } finally { c.close(); }
      }

      final data = await File(apkPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final tar = TarDecoder().decodeBytes(tarData);

      String? extractedBin;
      for (final entry in tar) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name.endsWith('/') || name.isEmpty || name == '.') continue;
        if (name.startsWith('.')) continue;

        final outPath = '$rootfs/$name';
        await Directory(outPath).parent.create(recursive: true);

        if (entry.isFile && entry.content.isNotEmpty) {
          await File(outPath).writeAsBytes(entry.content as List<int>);
          if (name.contains(searchBin)) {
            extractedBin = outPath;
          }
        }
      }
      try { await File(apkPath).delete(); } catch (_) {}
      return extractedBin;
    } catch (e) {
      _logMsg('Error $pkgName: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════
  // runCommand: linker64 + binario statico Alpine
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;
    if (linker == null) { _lastOutput = '[Error] linker64 no encontrado'; return _lastOutput; }

    try {
      // Limpiar shell syntax
      String cmd = command
          .replaceAll(RegExp(r'\s*2>&1\s*'), ' ')
          .replaceAll(RegExp(r'\s*2>/dev/null\s*'), ' ')
          .replaceAll(RegExp(r'\s*>\s*/dev/null\s*'), ' ')
          .replaceAll(RegExp(r'\s*\|\|\s*true\s*'), ' ')
          .replaceAll(RegExp(r'\s*\|\|\s*false\s*'), ' ')
          .replaceAll(RegExp(r'\s*\|.*$'), '')
          .replaceAll(RegExp(r'\s*&\s*$'), '')
          .trim();

      // Extraer primer comando
      final parts = cmd.split(' ');
      final binName = parts.isNotEmpty ? parts.first : '';
      final args = parts.length > 1 ? parts.sublist(1) : <String>[];
      if (binName.isEmpty) { _lastOutput = ''; return ''; }

      // ESTRATEGIA A: linker64 + binario estatico
      // Buscar en: apk.static, busybox.static, usr/local/bin, bin/, sbin/
      String? binPath;
      final appDir = await _appDir;

      if (binName == 'apk' && _apkStaticPath != null) {
        binPath = _apkStaticPath;
      } else if (_staticBusyboxPath != null &&
                 await File(_staticBusyboxPath!).exists()) {
        // Usar busybox static con el applet deseado
        // Ej: "ls /etc" -> linker64 busybox.static ls /etc
        binPath = _staticBusyboxPath;
        args.insert(0, binName); // busybox ls args...
      }

      // Si no encontramos binario estatico, buscar en rootfs
      if (binPath == null) {
        for (final d in ['/usr/local/bin', '/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
          final c = File('$rootfs$d/$binName');
          if (await c.exists() && await c.length() > 100) {
            binPath = c.path;
            // Intentar con linker64 directo (funciona con estaticos)
            break;
          }
        }
      }

      if (binPath != null && await File(binPath).exists()) {
        _logMsg('run: $binName ${args.join(" ")}');
        final result = await Process.run(
          linker, [binPath, ...args],
          environment: {
            'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                    '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                    ':/system/bin:/system/xbin',
            'HOME': '/root', 'TERM': 'xterm-256color',
            'LD_LIBRARY_PATH': '/system/lib64:/vendor/lib64',
          },
          workingDirectory: rootfs,
        ).timeout(timeout);
        final out = result.stdout as String;
        final err = result.stderr as String;
        _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
        return _lastOutput;
      }

      // ESTRATEGIA B: system shell
      _logMsg('sys: $command');
      final result = await Process.run(
        '/system/bin/sh', ['-c', command],
        environment: {'PATH': '/system/bin:/system/xbin', 'TERM': 'xterm-256color'},
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException { _lastOutput = '\n[Timeout]\n'; return _lastOutput; }
      catch (e) { _lastOutput = '\n[Error] $e\n'; return _lastOutput; }
  }

  // ═══════════════════════════════════════════════════════
  // runShell: terminal interactiva con wrapper functions
  // ═══════════════════════════════════════════════════════
  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;
    final bb = _staticBusyboxPath;
    final apkS = _apkStaticPath;
    if (linker == null) return '[Error] linker64';

    // Si no tenemos busybox static, fallback a runCommand
    if (bb == null || !await File(bb).exists()) {
      return runCommand(command);
    }

    try {
      // Generar wrapper functions para binarios estaticos
      final w = StringBuffer();
      w.writeln('export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin');
      w.writeln('export HOME=/root');
      w.writeln('export TERM=xterm-256color');

      // apk wrapper
      if (apkS != null && await File(apkS).exists()) {
        w.writeln("apk() { $linker '$apkS' \"\$@\"; }");
      }

      // Wrappers para todos los binarios en usr/local/bin (bionic/Termux)
      for (final dir in ['/usr/local/bin']) {
        final d = Directory('$rootfs$dir');
        if (await d.exists()) {
          try {
            await for (final f in d.list(followLinks: false)) {
              if (f is File && await f.length() > 10000) {
                final n = f.uri.pathSegments.last;
                if (n != 'apk') {
                  w.writeln("$n() { $linker '${f.path}' \"\$@\"; }");
                }
              }
            }
          } catch (_) {}
        }
      }

      w.writeln(command);

      final result = await Process.run(
        linker, [bb, 'sh', '-c', w.toString()],
        environment: {
          'LD_LIBRARY_PATH': '/system/lib64:/vendor/lib64',
        },
        workingDirectory: rootfs,
      ).timeout(timeout);

      final out = result.stdout as String;
      final err = result.stderr as String;
      return err.isNotEmpty ? '$out\n$err' : out;
    } on TimeoutException { return '\n[Timeout]\n'; }
      catch (e) { return '\n[Error] $e\n'; }
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
      if (!ok) throw Exception('No se pudo crear el rootfs');
      _logMsg('Rootfs Alpine OK');

      // 2: Reparar
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      // 3: DNS
      _downloadProgress = 0.40;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // 4: Descargar APKINDEX
      _downloadProgress = 0.50;
      _statusMessage = 'Obteniendo indice de paquetes...';
      notifyListeners();
      await _resolveVersion('busybox-static', rootfs); // download APKINDEX

      // 5: Descargar busybox-static y apk-tools-static
      _downloadProgress = 0.60;
      _statusMessage = 'Descargando busybox static...';
      notifyListeners();

      final bbVer = await _resolveVersion('busybox-static', rootfs);
      if (bbVer.isNotEmpty) {
        _logMsg('busybox-static version: $bbVer');
        final extracted = await _downloadAndExtract(
            'busybox-static', bbVer, rootfs, 'busybox.static');
        if (extracted != null) {
          _staticBusyboxPath = extracted;
          _logMsg('busybox.static: $extracted');
        }
      }

      _downloadProgress = 0.70;
      _statusMessage = 'Descargando apk-tools-static...';
      notifyListeners();

      final apkVer = await _resolveVersion('apk-tools-static', rootfs);
      if (apkVer.isNotEmpty) {
        _logMsg('apk-tools-static version: $apkVer');
        final extracted = await _downloadAndExtract(
            'apk-tools-static', apkVer, rootfs, 'apk.static');
        if (extracted != null) {
          _apkStaticPath = extracted;
          _logMsg('apk.static: $extracted');
        }
      }

      // 6: Verificar
      _downloadProgress = 0.80;
      _statusMessage = 'Verificando binarios...';
      notifyListeners();

      if (_staticBusyboxPath != null && await await File(_staticBusyboxPath!).exists()) {
        final sz = await File(_staticBusyboxPath!).length();
        _logMsg('busybox.static OK: $sz bytes');
      } else {
        _logMsg('WARNING: busybox.static no disponible');
      }

      if (_apkStaticPath != null && await File(_apkStaticPath!).exists()) {
        final sz = await File(_apkStaticPath!).length();
        _logMsg('apk.static OK: $sz bytes');
      } else {
        _logMsg('WARNING: apk.static no disponible');
      }

      // 7: Test basico
      if (_staticBusyboxPath != null) {
        try {
          final test = await runCommand('ls /etc',
              timeout: const Duration(seconds: 10));
          _logMsg('Test ls: ${test.length > 60 ? test.substring(0,60)+"..." : (test.isEmpty ? "(vacio)" : test)}');
        } catch (e) { _logMsg('Test ls fallo: $e'); }
      }

      // 8: Instalar paquetes esenciales
      _downloadProgress = 0.90;
      _statusMessage = 'Instalando paquetes esenciales...';
      notifyListeners();
      await installEssentials();

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

  // ─── installEssentials ───
  Future<void> installEssentials() async {
    _logMsg('=== Instalando paquetes esenciales ===');
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';

    if (_apkStaticPath != null && await File(_apkStaticPath!).exists()) {
      // apk update
      _statusMessage = 'Actualizando repositorios...';
      notifyListeners();
      try {
        final up = await runCommand('apk update',
            timeout: const Duration(seconds: 120));
        _logMsg('apk update: ${up.length > 200 ? up.substring(0,200)+"..." : up}');
      } catch (e) { _logMsg('apk update: $e'); }

      // Instalar paquetes
      final pkgs = ['openssh-server', 'openssh-keygen', 'curl', 'wget',
                    'bash', 'ca-certificates', 'sudo', 'nano'];
      for (final p in pkgs) {
        _statusMessage = 'Instalando $p...';
        notifyListeners();
        try {
          final r = await runCommand('apk add --no-scripts $p',
              timeout: const Duration(seconds: 180));
          _logMsg('$p: ${r.length > 100 ? r.substring(0,100)+"..." : r}');
        } catch (e) { _logMsg('$p fallo: $e'); }
      }
    } else {
      _logMsg('apk.static no disponible, instalando via Dart');
      // Fallback: descargar .apk directamente
      for (final pkgName in ['openssh-server', 'openssh-keygen',
                             'curl', 'wget', 'bash']) {
        final ver = await _resolveVersion(pkgName, rootfs);
        if (ver.isNotEmpty) {
          _logMsg('Instalando $pkgName-$ver via Dart');
          await _downloadAndExtract(pkgName, ver, rootfs, '');
        }
      }
    }

    // SSH keys
    _statusMessage = 'Configurando SSH...';
    notifyListeners();
    _logMsg('Generando claves SSH...');
    try {
      final keys = await runCommand('ssh-keygen -A',
          timeout: const Duration(seconds: 30));
      _logMsg('ssh-keys: ${keys.length > 100 ? keys.substring(0,100)+"..." : keys}');
    } catch (e) { _logMsg('ssh-keygen: $e'); }

    _logMsg('=== Paquetes esenciales OK ===');
    _statusMessage = 'Paquetes instalados';
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════
  // Funciones auxiliares
  // ═══════════════════════════════════════════════════════
  Future<bool> _setupFromAsset(String rootfs) async {
    try {
      if (!(await rootBundle.loadString('AssetManifest.json'))
          .contains('assets/rootfs.tar.gz')) return false;
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      final bytes = data.buffer.asUint8List();
      final appDir = await _appDir;
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      await File(tarPath).writeAsBytes(bytes);

      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try {
            final r = await Process.run(
              tb, ['tar', '-xzf', tarPath, '-C', rootfs])
                .timeout(const Duration(seconds: 180));
            if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
                await File('$rootfs/bin/sh').length() > 0) return true;
          } catch (e) {}
        }
      }
      return _extractTarDart(tarPath, rootfs);
    } catch (e) { return false; }
  }

  Future<bool> _extractTarDart(String tgz, String rootfs) async {
    try {
      final bytes = await File(tgz).readAsBytes();
      final arch = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      for (final entry in arch) {
        String n = entry.name;
        if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        final out = '$rootfs/$n';
        if (n.endsWith('/')) { await Directory(out).create(recursive: true); continue; }
        await Directory(out).parent.create(recursive: true);
        if (entry.isSymbolicLink) {
          final t = entry.symbolicLink ?? '';
          if (t.startsWith('/')) {
            final r = File('$rootfs$t');
            if (await r.exists() && await r.length() > 0) {
              try { if (await Link(out).exists()) await Link(out).delete(); } catch (_) {}
              try { await File(out).writeAsBytes(await r.readAsBytes()); } catch (_) {}
            }
          }
          continue;
        }
        if (entry.isFile && entry.content.isNotEmpty) {
          await File(out).writeAsBytes(entry.content);
        }
      }
      return true;
    } catch (e) { return false; }
  }

  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) return false;
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          final r = await Process.run(
            tb, ['tar', '-xzf', tgzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (e) {}
      }
    }
    return _extractTarDart(tgzPath, rootfs);
  }

  Future<void> _fixHardlinks(String rootfs) async {
    int n = 0;
    final bb = File('$rootfs/bin/busybox');
    List<int>? d;
    if (await bb.exists() && await bb.length() > 0) d = await bb.readAsBytes();
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
      final dd = Directory('$rootfs$dir');
      if (!await dd.exists()) continue;
      try {
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
    _staticBusyboxPath = null; _apkStaticPath = null;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
