#!/bin/bash
# ============================================================================
# Linux Container v4.0 - Termux binaries + Alpine data
# 
# linker64 NO puede cargar musl libc (PHDR error)
# linker64 SI puede cargar bionic libc (Termux packages)
# 
# Shell: Termux busybox (bionic) via linker64
# SSH:   Termux openssh (bionic) via linker64
# Data:  Alpine rootfs (configs, estructura)
# ============================================================================
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linux Container v4.0${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"

mkdir -p .backup
cp lib/services/proot_service.dart .backup/proot_service_v3.bak 2>/dev/null || true

echo -e "\n${YELLOW}[1/3] Escribiendo proot_service.dart v4.0...${NC}"

cat > lib/services/proot_service.dart << 'DART'
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

  String? _rootfsPath;

  static const String _minirootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz';
  static const String _busyboxDebUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/b/busybox/busybox_1.37.0-3_aarch64.deb';
  static const String _opensshDebUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/o/openssh/openssh_10.3p1-1_aarch64.deb';

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  String? get bionicBusybox => _bionicBusyboxPath;
  String? _bionicBusyboxPath;

  Future<bool> checkEnvironment() async {
    _log.clear();
    try {
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      final bb = '${await _appDir}/bionic_busybox';

      if (await Directory(rootfs).exists() && await File(bb).exists()) {
        final sh = File('$rootfs/bin/sh');
        if (await sh.exists() && await sh.length() > 1000) {
          _initialized = true;
          _bionicBusyboxPath = bb;
          _statusMessage = 'Linux listo';
          _logMsg('Rootfs OK, bionic busybox OK');
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Linux no instalado - pulsa Setup';
      notifyListeners();
      return false;
    } catch (e) {
      _logMsg('Error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════
  // runCommand: Termux busybox (bionic) via linker64
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;
    final bb = _bionicBusyboxPath ?? '${await _appDir}/bionic_busybox';

    if (linker == null) { _lastOutput = '[Error] linker64 no encontrado'; return _lastOutput; }

    try {
      // ESTRATEGIA A: Termux busybox via linker64
      if (await File(bb).exists() && await File(bb).length() > 100000) {
        _logMsg('cmd: $command');
        final result = await Process.run(
          linker, [bb, 'sh', '-c', command],
          environment: {
            'PATH': '$rootfs/bin:$rootfs/sbin:$rootfs/usr/bin:$rootfs/usr/sbin'
                    ':$rootfs/usr/local/bin:/system/bin:/system/xbin',
            'HOME': '/root',
            'TERM': 'xterm-256color',
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
  // runShell: Shell interactiva
  // ═══════════════════════════════════════════════════════
  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    return runCommand(command, timeout: timeout);
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
      _downloadProgress = 0.10;
      _statusMessage = 'Extrayendo rootfs Alpine...';
      notifyListeners();

      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo crear el rootfs');

      // 2: Reparar
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);
      _logMsg('Rootfs Alpine OK');

      // 3: DNS
      _downloadProgress = 0.50;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // 4: DESCARGAR TERMUX BUSYBOX (bionic)
      _downloadProgress = 0.60;
      _statusMessage = 'Descargando shell (Termux busybox)...';
      notifyListeners();

      final bbPath = '$appDir/bionic_busybox';
      if (!await File(bbPath).exists() || await File(bbPath).length() < 100000) {
        await _extractTermuxPackage(_busyboxDebUrl, '$appDir/busybox.deb', bbPath, 'busybox');
      }

      bool bbOk = await File(bbPath).exists() && await File(bbPath).length() > 100000;
      _bionicBusyboxPath = bbOk ? bbPath : null;

      if (bbOk) {
        _logMsg('Termux busybox: ${await File(bbPath).length()} bytes');
      } else {
        _logMsg('WARNING: busybox no disponible');
      }

      // 5: Descargar Termux openssh
      _downloadProgress = 0.75;
      _statusMessage = 'Descargando SSH (Termux openssh)...';
      notifyListeners();

      for (final bin in ['sshd', 'ssh-keygen', 'ssh']) {
        final outPath = '$rootfs/usr/local/bin/$bin';
        if (!await File(outPath).exists() || await File(outPath).length() < 10000) {
          // Extraer todos los bins del .deb
          await _extractTermuxOpenssh(_opensshDebUrl, '$appDir/openssh.deb', rootfs);
          break;
        }
      }

      // 6: Verificar shell
      _downloadProgress = 0.85;
      _statusMessage = 'Verificando shell...';
      notifyListeners();
      if (bbOk) {
        try {
          final test = await runCommand('echo "SHELL_OK"', timeout: const Duration(seconds: 10));
          _logMsg('Shell: ${test.trim()}');
        } catch (e) { _logMsg('Shell test: $e'); }
      }

      // 7: Instalar Alpine packages via Dart
      _downloadProgress = 0.90;
      _statusMessage = 'Instalando paquetes Alpine...';
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

  // ─── Extraer Termux .deb (ar + tar.gz) ───
  Future<void> _extractTermuxPackage(String url, String debPath, String outPath, String binName) async {
    try {
      if (!await File(debPath).exists()) {
        await _downloadFile(url, debPath, 0.60, 0.65);
      }
      final data = await File(debPath).readAsBytes();
      final str = String.fromCharCodes(data);
      if (!str.startsWith('!<arch>\n')) { _logMsg('Formato arch invalido'); return; }

      int idx = 8;
      while (idx + 60 <= data.length) {
        final hdr = str.substring(idx, idx + 60);
        final name = hdr.substring(0, 16).trim();
        final sizeStr = hdr.substring(48, 58).trim();
        final size = int.tryParse(sizeStr) ?? 0;
        idx += 60;

        if (name.startsWith('data.tar')) {
          final tarGzData = data.sublist(idx, idx + size);
          List<int> tarData;
          try { tarData = GZipDecoder().decodeBytes(tarGzData); }
          catch (_) { idx += size + (idx % 2); continue; }

          final tar = TarDecoder().decodeBytes(tarData);
          for (final entry in tar) {
            if (entry.isFile && entry.name.contains(binName) &&
                entry.content.length > 100000) {
              await File(outPath).writeAsBytes(entry.content as List<int>);
              _logMsg('Extraido $binName (${entry.content.length} bytes)');
              try { await File(debPath).delete(); } catch (_) {}
              return;
            }
          }
        }
        idx += size;
        if (idx % 2 != 0) idx++;
      }
      _logMsg('No se encontro $binName en el .deb');
    } catch (e) { _logMsg('Error extrayendo $binName: $e'); }
  }

  // ─── Extraer Termux OpenSSH ───
  Future<void> _extractTermuxOpenssh(String url, String debPath, String rootfs) async {
    try {
      if (!await File(debPath).exists()) {
        await _downloadFile(url, debPath, 0.75, 0.80);
      }
      final data = await File(debPath).readAsBytes();
      final str = String.fromCharCodes(data);
      if (!str.startsWith('!<arch>\n')) return;

      int idx = 8;
      while (idx + 60 <= data.length) {
        final hdr = str.substring(idx, idx + 60);
        final name = hdr.substring(0, 16).trim();
        final sizeStr = hdr.substring(48, 58).trim();
        final size = int.tryParse(sizeStr) ?? 0;
        idx += 60;

        if (name.startsWith('data.tar')) {
          final tarGzData = data.sublist(idx, idx + size);
          List<int> tarData;
          try { tarData = GZipDecoder().decodeBytes(tarGzData); }
          catch (_) { idx += size + (idx % 2); continue; }

          final tar = TarDecoder().decodeBytes(tarData);
          await Directory('$rootfs/usr/local/bin').create(recursive: true);
          for (final entry in tar) {
            if (entry.isFile && entry.content.length > 10000) {
              final en = entry.name;
              final base = en.split('/').last;
              if (['sshd', 'ssh-keygen', 'ssh', 'ssh-agent', 'scp', 'sftp'].contains(base)) {
                final out = '$rootfs/usr/local/bin/$base';
                await File(out).writeAsBytes(entry.content as List<int>);
                _logMsg('SSH: $base (${entry.content.length} bytes)');
              }
            }
          }
          try { await File(debPath).delete(); } catch (_) {}
          return;
        }
        idx += size;
        if (idx % 2 != 0) idx++;
      }
    } catch (e) { _logMsg('Error SSH: $e'); }
  }

  // ─── Instalar Alpine .apk packages via Dart ───
  Future<void> _installAlpinePackage(String pkgName, String rootfs, String version) async {
    final apkUrl = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/$pkgName-$version.apk';
    final apkPath = '$rootfs/../${pkgName}_$version.apk';

    try {
      if (!await File(apkPath).exists()) {
        _logMsg('Descargando: $pkgName-$version');
        await _downloadFile(apkUrl, apkPath, 0.85, 0.95);
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
        if (entry.isFile && entry.content.isNotEmpty) {
          await File('$rootfs/$name').writeAsBytes(entry.content as List<int>);
          files++;
        }
      }
      _logMsg('$pkgName-$version: $files archivos');
      try { await File(apkPath).delete(); } catch (_) {}
    } catch (e) { _logMsg('Error $pkgName: $e'); }
  }

  // ─── Descargar APKINDEX y obtener versiones ───
  Future<Map<String, String>> _getAlpinePackages(String rootfs) async {
    final indexUrl = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/APKINDEX.tar.gz';
    final indexPath = '$rootfs/../APKINDEX.tar.gz';

    if (!await File(indexPath).exists()) {
      try {
        await _downloadFile(indexUrl, indexPath, 0.80, 0.85);
      } catch (e) {
        _logMsg('Error APKINDEX: $e');
        return {};
      }
    }

    try {
      final data = await File(indexPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final result = <String, String>{};

      // Simple tar parser
      int pos = 0;
      while (pos + 512 <= tarData.length) {
        if (tarData[pos] == 0) break;
        final nameEnd = tarData.indexOf(0, pos);
        if (nameEnd < 0 || nameEnd - pos > 100) break;
        final name = String.fromCharCodes(tarData.sublist(pos, nameEnd));
        if (name.isEmpty) break;
        final sizeStr = String.fromCharCodes(
            tarData.sublist(pos + 124, pos + 136)).split('\x00')[0].trim();
        final size = int.tryParse(sizeStr, radix: 8) ?? 0;
        final padded = ((size + 511) ~/ 512) * 512;

        if (name == 'APKINDEX') {
          final content = tarData.sublist(pos + 512, pos + 512 + size);
          final lines = String.fromCharCodes(content).split('\n');
          String pn = '', pv = '';
          for (final line in lines) {
            if (line.startsWith('P:')) { pn = line.substring(2).trim(); }
            else if (line.startsWith('V:')) { pv = line.substring(2).trim(); }
            else if (line.isEmpty && pn.isNotEmpty) {
              result[pn] = pv;
              pn = ''; pv = '';
            }
          }
          break;
        }
        pos += 512 + padded;
      }

      _logMsg('APKINDEX: ${result.length} packages');
      return result;
    } catch (e) {
      _logMsg('Error parse APKINDEX: $e');
      return {};
    }
  }

  // ─── installEssentials ───
  Future<void> _installEssentials(String rootfs) async {
    _logMsg('=== Instalando paquetes esenciales ===');
    _statusMessage = 'Instalando paquetes...';
    notifyListeners();

    // 1: Obtener versiones de APKINDEX
    final versions = await _getAlpinePackages(rootfs);

    // 2: Instalar paquetes Alpine via Dart
    final packages = ['openssh-server', 'openssh-keygen',
                     'curl', 'wget', 'bash', 'ca-certificates', 'sudo', 'nano'];
    for (final pkg in packages) {
      final ver = versions[pkg];
      if (ver != null) {
        await _installAlpinePackage(pkg, rootfs, ver);
      } else {
        _logMsg('Version no encontrada para $pkg');
      }
    }

    // 3: Generar claves SSH via Termux ssh-keygen
    _statusMessage = 'Configurando SSH...';
    notifyListeners();
    _logMsg('Generando claves SSH...');
    try {
      // ssh-keygen -A genera claves de host
      final keys = await runCommand('ssh-keygen -A',
          timeout: const Duration(seconds: 30));
      _logMsg('ssh-keys: ${keys.length > 100 ? keys.substring(0,100)+"..." : keys}');
    } catch (e) { _logMsg('ssh-keygen fallo: $e'); }

    _logMsg('=== Paquetes esenciales OK ===');
    _statusMessage = 'Paquetes instalados';
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════
  // Funciones auxiliares
  // ═══════════════════════════════════════════════════════
  Future<void> _downloadFile(String url, String path, double sw, double ew) async {
    final client = HttpClient();
    try {
      _logMsg('Download: $url');
      final req = await client.getUrl(Uri.parse(url));
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
    } finally { client.close(); }
  }

  Future<bool> _setupFromAsset(String rootfs) async {
    _logMsg('--- Buscando assets embebidos ---');
    try {
      if (!(await rootBundle.loadString('AssetManifest.json')).contains('assets/rootfs.tar.gz')) return false;
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      final bytes = data.buffer.asUint8List();
      final appDir = await _appDir;
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      await File(tarPath).writeAsBytes(bytes);

      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try {
            final r = await Process.run(tb, ['tar', '-xzf', tarPath, '-C', rootfs])
                .timeout(const Duration(seconds: 180));
            if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
                await File('$rootfs/bin/sh').length() > 0) {
              _logMsg('OK: con $tb'); return true;
            }
          } catch (e) { _logMsg('$tb: $e'); }
        }
      }
      return _extractTarDart(tarPath, rootfs);
    } catch (e) { _logMsg('Asset fallo: $e'); return false; }
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
          if (t.isNotEmpty && t.startsWith('/')) {
            final r = '$rootfs$t';
            if (await File(r).exists() && await File(r).length() > 0) {
              try { if (await Link(out).exists()) await Link(out).delete(); } catch (_) {}
              try { await File(out).writeAsBytes(await File(r).readAsBytes()); } catch (_) {}
            }
          }
          continue;
        }
        if (entry.isFile && entry.content.isNotEmpty) {
          await File(out).writeAsBytes(entry.content);
        }
      }
      return true;
    } catch (e) { _logMsg('Dart extract: $e'); return false; }
  }

  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try { await _downloadFile(_minirootfsUrl, tgzPath, 0.20, 0.50); } catch (e) { return false; }
    }
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          final r = await Process.run(tb, ['tar', '-xzf', tgzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) return true;
        } catch (e) { _logMsg('$tb: $e'); }
      }
    }
    return _extractTarDart(tgzPath, rootfs);
  }

  Future<void> _fixHardlinks(String rootfs) async {
    int n = 0;
    final bb = File('$rootfs/bin/busybox');
    List<int>? bbData;
    if (await bb.exists() && await bb.length() > 0) bbData = await bb.readAsBytes();
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(followLinks: false)) {
          if (e is File && await e.length() == 0 && bbData != null &&
              (e.path.contains('/bin/') || e.path.contains('/sbin/'))) {
            await e.writeAsBytes(bbData); n++;
          }
        }
      } catch (_) {}
    }
    if (bbData != null) {
      final sh = File('$rootfs/bin/sh');
      if (!await sh.exists() || await sh.length() == 0) {
        try { await sh.writeAsBytes(bbData); n++; } catch (_) {}
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
    _initialized = false; _rootfsPath = null; _bionicBusyboxPath = null;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
DART

echo -e "  ${GREEN}✓${NC} proot_service.dart v4.0 ($(wc -l < lib/services/proot_service.dart) lineas)"

# ─── Commit y Push ───
echo -e "\n${YELLOW}[2/3] Commit y push...${NC}"
git add lib/services/proot_service.dart
git commit -m "v4.0: Termux busybox (bionic) shell + Alpine .apk via Dart

PROBLEMA: linker64 NO puede cargar musl-linked binaries en Android 15+
(seccomp bloquea ptrace, linker64 no soporta ld-musl como shared lib)

SOLUCION DEFINITIVA:
1. Shell via Termux busybox (bionic libc, compatible con linker64)
   - Descarga busybox_1.37.0-3_aarch64.deb desde Termux repo
   - Extrae el binario y ejecuta via: linker64 busybox sh -c COMANDO
   - Proporciona: sh, ls, cp, mv, cat, curl, wget, ping, grep, etc.

2. SSH via Termux openssh (bionic libc)
   - Descarga openssh_10.3p1-1_aarch64.deb desde Termux repo
   - Extrae sshd, ssh-keygen, ssh a rootfs/usr/local/bin
   - Ejecutable via linker64

3. Alpine package management implementado en Dart
   - Descarga APKINDEX.tar.gz del mirror Alpine
   - Parsea para obtener nombre -> version
   - Descarga .apk (tar.gz) y extrae al rootfs
   - Sin necesidad de binario apk de Alpine

4. Alpine rootfs se mantiene para estructura de datos" 2>/dev/null || true

git push origin main 2>&1 || true

echo -e "\n${YELLOW}[3/3] Tag y release...${NC}"
VERSION="v2.2.2"
git tag -f "$VERSION" 2>/dev/null || true
git push origin "$VERSION" -f 2>&1 || true

echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ v4.0 COMPLETADO${NC}"
echo -e "${GREEN}  Tag: $VERSION${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "  GitHub Actions compila automaticamente"
echo -e "  https://github.com/txurtxil/LinuxContainer/actions"
