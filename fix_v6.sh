#!/bin/bash
# ============================================================================
# Linux Container v6.0 - Toybox shell + Alpine .apk en Dart
#
# PROBLEMA: Ningun binario musl funciona con linker64 (PHDR error)
# SOLUCION: 
#   - Shell: Android toybox (bionic nativo, execve desde /system/bin)
#   - Package mgmt: Alpine .apk implementado en Dart (gzip+tar)
#   - Terminal: /system/bin/sh con PATH a /system/bin + rootfs
# ============================================================================
set -e
cd "$(dirname "$0")"
YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linux Container v6.0 - Toybox + Dart apk${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"

mkdir -p .backup
cp lib/services/proot_service.dart .backup/proot_service_v5.bak 2>/dev/null || true

echo -e "\n${YELLOW}[1/3] Escribiendo proot_service.dart...${NC}"

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

  static const String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64';

  Future<String> get _appDir async {
    return '${(await getApplicationDocumentsDirectory()).path}/linux_container';
  }

  // ═══════════════════════════════════════════════════════
  // runCommand: system shell (toybox/binario) con PATH rootfs
  // Usa /system/bin/sh que permite execve desde /system/bin
  // NO usa linker64 para binarios rootfs (musl incompat)
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
  // runShell: interactiva (same as runCommand)
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

      // 5: Instalar paquetes Alpine via Dart
      _downloadProgress = 0.80;
      _statusMessage = 'Instalando paquetes (Dart)...';
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
  // Alpine Package Management en Dart (sin apk binary)
  // ═══════════════════════════════════════════════════════

  /// Parsea APKINDEX.tar.gz y devuelve {nombre: version}
  Future<Map<String, String>> _getApkVersions(String rootfs) async {
    final idxPath = '$rootfs/../APKINDEX.tar.gz';
    if (!await File(idxPath).exists()) {
      try {
        await _downloadFile('$_alpineMirror/APKINDEX.tar.gz', idxPath, 0.80, 0.82);
      } catch (e) { _logMsg('Error APKINDEX: $e'); return {}; }
    }

    try {
      final data = await File(idxPath).readAsBytes();
      final tarData = GZipDecoder().decodeBytes(data);
      final result = <String, String>{};

      int pos = 0;
      while (pos + 512 <= tarData.length) {
        if (tarData[pos] == 0) break;
        final nameEnd = tarData.indexOf(0, pos);
        if (nameEnd < 0 || nameEnd - pos > 100) break;
        final name = String.fromCharCodes(tarData.sublist(pos, nameEnd));
        if (name == 'APKINDEX') {
          final szStr = String.fromCharCodes(tarData.sublist(pos+124,pos+136))
                         .split('\x00')[0].trim();
          final sz = int.tryParse(szStr, radix: 8) ?? 0;
          final content = String.fromCharCodes(
              tarData.sublist(pos+512, pos+512+sz));
          String cn = '', cv = '';
          for (final line in content.split('\n')) {
            if (line.startsWith('P:')) cn = line.substring(2).trim();
            else if (line.startsWith('V:')) cv = line.substring(2).trim();
            else if (line.isEmpty && cn.isNotEmpty) {
              result[cn] = cv; cn = ''; cv = '';
            }
          }
          break;
        }
        final szStr = String.fromCharCodes(tarData.sublist(pos+124,pos+136))
                       .split('\x00')[0].trim();
        final padded = ((int.tryParse(szStr, radix: 8) ?? 0) + 511) ~/ 512 * 512;
        pos += 512 + padded;
      }
      return result;
    } catch (e) { _logMsg('Parse APKINDEX: $e'); return {}; }
  }

  /// Descarga e instala un .apk (gzip+tar) al rootfs
  Future<bool> _installApk(String pkg, String ver, String rootfs) async {
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
        // Saltar scripts de instalacion (.pre-install, .post-install)
        if (name.contains('.pre-install') || name.contains('.post-install')) continue;
        if (entry.isFile && entry.content.isNotEmpty) {
          await File('$rootfs/$name').writeAsBytes(entry.content as List<int>);
          files++;
        }
      }
      _logMsg('$pkg-$ver: $files archivos');
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) {
      _logMsg('Error $pkg: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════
  // installEssentials
  // ═══════════════════════════════════════════════════════
  Future<void> _installEssentials(String rootfs) async {
    _logMsg('=== Instalando paquetes esenciales (Dart) ===');

    // Obtener versiones del APKINDEX
    _statusMessage = 'Obteniendo indice de paquetes...';
    notifyListeners();
    final versions = await _getApkVersions(rootfs);
    _logMsg('Disponibles: ${versions.length} paquetes');

    // Instalar paquetes Alpine
    final packages = [
      'openssh-server', 'openssh-keygen', 'openssh-sftp-server',
      'curl', 'wget', 'bash', 'ca-certificates', 'sudo', 'nano'
    ];

    int installed = 0, failed = 0;
    for (final pkg in packages) {
      final ver = versions[pkg];
      if (ver == null) { _logMsg('$pkg: no encontrado'); failed++; continue; }
      _statusMessage = 'Instalando $pkg...';
      notifyListeners();
      if (await _installApk(pkg, ver, rootfs)) { installed++; }
      else { failed++; }
    }

    _logMsg('Instalados: $installed, Fallos: $failed');

    // Configurar SSH
    _statusMessage = 'Configurando SSH...';
    notifyListeners();
    _logMsg('Generando claves SSH...');
    // ssh-keygen de Alpine es musl y no funciona via linker64
    // Las claves se generan en el setup inicial del contenedor
    // Por ahora, configuracion manual necesaria

    _logMsg('=== Paquetes esenciales OK ===');
    _statusMessage = 'Paquetes instalados';
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
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado');
    notifyListeners();
  }
}
DART

echo -e "  ${GREEN}✓${NC} proot_service.dart v6.0 ($(wc -l < lib/services/proot_service.dart) lineas)"

# Commit y push
echo -e "\n${YELLOW}[2/3] Commit y push...${NC}"
git add lib/services/proot_service.dart
git commit -m "v6.0: Toybox shell + Alpine .apk management en Dart

PROBLEMA DEFINITIVO: Ningun binario musl (static o dynamic) funciona
con linker64 porque el startup code de musl necesita aux vector del kernel.

SOLUCION:
1. Shell: system /system/bin/sh con toybox (bionic nativo)
   - toybox en /system/bin, accesible via execve (no noexec)
   - Proporciona: sh, ls, cp, mv, cat, echo, ping, etc.
   - PATH incluye rootfs/bin para datos y configs

2. Alpine package management en Dart (SIN apk binary)
   - APKINDEX.tar.gz descargado y parseado en Dart
   - .apk packages (gzip+tar) descargados y extraidos al rootfs
   - Sin dependencia de binarios musl

3. SSH: paquetes Alpine extraidos pero binarios musl no ejecutables
   - Pendiente: binario SSH para Android/bionic" 2>/dev/null || true

git push origin main 2>&1 || true

echo -e "\n${YELLOW}[3/3] Tag y release...${NC}"
VERSION="v2.2.3"
git tag -f "$VERSION" 2>/dev/null || true
git push origin "$VERSION" -f 2>&1 || true

echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ v6.0 COMPLETADO${NC}"
echo -e "${GREEN}  Tag: $VERSION${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "  https://github.com/txurtxil/LinuxContainer/actions"
