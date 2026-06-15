#!/bin/bash
# ============================================================================
# Linux Container App v9.0 - Build & Release Script COMPLETO
# 
# Este script compila la APK, inyecta permisos Android y publica
# en GitHub Releases.
#
# Uso: bash build_final.sh [--release]
#   --release: Publica release en GitHub automaticamente
# ============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linux Container v9.0 - Builder${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"

# ─── Variables ───
ARCH=$(uname -m)
VERSION="v9.0"
RELEASE=${1:-}

# ─── 1. Verificar entorno ───
echo -e "\n${YELLOW}[1/6] Verificando entorno...${NC}"

# Detectar si estamos en CI (GitHub Actions) o local
if [ -n "$GITHUB_ACTIONS" ]; then
    echo -e "  ${BLUE}→${NC} Entorno CI detectado"
    CI=true
else
    echo -e "  ${BLUE}→${NC} Entorno local: $ARCH"
    CI=false
fi

# Flutter
if ! command -v flutter &> /dev/null; then
    if [ "$CI" = false ]; then
        echo -e "  ${YELLOW}⚠ Instalando Flutter...${NC}"
        curl -sL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.1-stable.tar.xz" -o /tmp/flutter.tar.xz
        tar -xf /tmp/flutter.tar.xz -C /opt/ 2>/dev/null || sudo tar -xf /tmp/flutter.tar.xz -C /opt/ 2>/dev/null
        export PATH="/opt/flutter/bin:$PATH"
    else
        echo -e "  ${GREEN}✓${NC} Flutter en CI"
    fi
fi

# Android SDK
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
if [ ! -d "$ANDROID_HOME/platforms" ]; then
    echo -e "  ${YELLOW}⚠ Configurando Android SDK...${NC}"
    yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null 2>&1 || true
    flutter config --android-sdk "$ANDROID_HOME" > /dev/null 2>&1 || true
fi

echo -e "  ${GREEN}✓${NC} Flutter: $(flutter --version 2>&1 | head -1)"
echo -e "  ${GREEN}✓${NC} Android SDK: $ANDROID_HOME"
echo ""

# ─── 2. Escribir código fuente ───
echo -e "${YELLOW}[2/6] Escribiendo código fuente...${NC}"

# main.dart
cat > lib/main.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/proot_service.dart';
import 'services/terminal_service.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LinuxContainerApp());
}

class LinuxContainerApp extends StatelessWidget {
  const LinuxContainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProotService()),
        ChangeNotifierProvider(create: (_) => TerminalService()),
      ],
      child: MaterialApp(
        title: 'Linux Container',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.dark),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const HomeScreen(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: Colors.teal,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0D1117) : null,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF161B22) : null,
        centerTitle: true,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF161B22) : null,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: isDark ? const Color(0xFF21262D) : null,
      ),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} main.dart"

# proot_service.dart (COMPLETO - usando Termux bootstrap para bionic bins)
cat > lib/services/proot_service.dart << 'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier {
  // ─── SINGLETON ───
  static final ProotService _instance = ProotService._internal();
  factory ProotService() => _instance;
  ProotService._internal();

  // ─── ESTADO ───
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
  String? _rootfsPath;
  String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main';

  // ══════════════════════════════════════════════
  // GETTERS
  // ══════════════════════════════════════════════
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

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';

  Future<String> getArchitecture() async {
    if (_arch.isNotEmpty) return _arch;
    try {
      final r = await Process.run('uname', ['-m']).timeout(const Duration(seconds: 5));
      final a = (r.stdout as String).trim();
      if (a == 'aarch64' || a == 'arm64') _arch = 'aarch64';
      else if (a == 'x86_64' || a == 'amd64') _arch = 'x86_64';
      else if (a.startsWith('armv')) _arch = 'armv7';
      else _arch = a;
    } catch (e) { _arch = 'aarch64'; }
    _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/$_arch';
    _logMsg('Arquitectura: $_arch');
    return _arch;
  }

  // ══════════════════════════════════════════════
  // runCommand
  // ══════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final termuxDir = '${await _appDir}/termux';
    try {
      String path = '/system/bin:/system/xbin';
      if (_bionicInstalled) path = '$termuxDir/bin:$termuxDir/bin/applets:$path';
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

  // ══════════════════════════════════════════════
  // checkEnvironment
  // ══════════════════════════════════════════════
  Future<bool> checkEnvironment() async {
    _log.clear();
    try {
      await getArchitecture();
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        if (st.size > 1000) { _initialized = true; _statusMessage = 'Linux listo'; }
      }
      final termuxDir = '${await _appDir}/termux';
      _bionicInstalled = await File('$termuxDir/bin/sshd').exists() && await File('$termuxDir/bin/bash').exists();
      if (_bionicInstalled) {
        _logMsg('Bionic OK (sshd, bash)');
        _statusMessage = 'Linux listo + bionic';
      } else if (_initialized) {
        _statusMessage = 'Linux listo (sin bionic)';
      }
      if (!_initialized && !_bionicInstalled) _statusMessage = 'Linux no instalado - pulsa Setup';
      notifyListeners();
      return _initialized || _bionicInstalled;
    } catch (e) { _logMsg('Error: $e'); return false; }
  }

  // ══════════════════════════════════════════════
  // setupEnvironment
  // ══════════════════════════════════════════════
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
      _downloadProgress = 0.05; notifyListeners();
      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo extraer rootfs Alpine');
      _logMsg('Rootfs Alpine OK');
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      // 2: Red
      _downloadProgress = 0.15; _statusMessage = 'Configurando red...'; notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString('127.0.0.1 localhost\n::1 localhost\n');

      // 3: Shell test
      _downloadProgress = 0.20; _statusMessage = 'Verificando sistema...'; notifyListeners();
      try { final t = await runCommand('echo "SHELL_OK"', timeout: const Duration(seconds: 10)); _logMsg('Shell: ${t.trim()}'); } catch (e) { _logMsg('Shell: $e'); }

      // 4: APKINDEX Alpine
      _downloadProgress = 0.25; _statusMessage = 'Cargando indice APK...'; notifyListeners();
      await _refreshApkIndex(rootfs);

      // 5: Termux bootstrap (bionic bins)
      _downloadProgress = 0.30; _statusMessage = 'Instalando binarios nativos (bionic)...'; notifyListeners();
      await _installTermuxBootstrap(appDir);

      // 6: SSH setup
      if (_bionicInstalled) {
        _downloadProgress = 0.85; _statusMessage = 'Configurando SSH...'; notifyListeners();
        await _setupBionicSsh(appDir);
      }

      _downloadProgress = 1.0; _initialized = true;
      _statusMessage = _bionicInstalled ? 'Linux listo + bionic (nano, sshd, bash OK)' : 'Linux listo (solo Alpine)';
      _logMsg('=== FIN SETUP ===');
    } catch (e) {
      _logMsg('EXCEPCION: $e'); _statusMessage = 'Error: $e'; _initialized = false;
    } finally {
      _isDownloading = false; _lastOutput = logText; notifyListeners();
    }
  }

  // ══════════════════════════════════════════════
  // TERMUX BOOTSTRAP
  // ══════════════════════════════════════════════
  Future<void> _installTermuxBootstrap(String appDir) async {
    final termuxDir = '$appDir/termux';
    await Directory(termuxDir).create(recursive: true);

    if (await File('$termuxDir/bin/nano').exists() && await File('$termuxDir/bin/sshd').exists() && await File('$termuxDir/bin/bash').exists()) {
      _bionicInstalled = true; _logMsg('Bionic bins OK (cached)'); return;
    }

    bool extracted = false;

    // Metodo 1: bionic-tools.tar.gz desde GitHub releases
    final tgzPath = '$appDir/bionic-tools.tar.gz';
    for (final url in [
      'https://github.com/txurtxil/LinuxContainer/releases/download/v8.5/bionic-tools.tar.gz',
      'https://github.com/txurtxil/LinuxContainer/releases/latest/download/bionic-tools.tar.gz',
    ]) {
      try {
        _logMsg('Descargando bionic-tools: $url');
        await _downloadFile(url, tgzPath, 0.35, 0.50);
        if (await File(tgzPath).length() > 10000) {
          final d = await File(tgzPath).readAsBytes();
          if (d.length >= 2 && d[0] == 0x1F && d[1] == 0x8B) {
            extracted = await _extractTarGz(tgzPath, termuxDir);
            if (extracted) { _logMsg('bionic-tools extraido OK'); break; }
          }
        }
      } catch (e) { _logMsg('URL fallo: $e'); }
    }
    try { if (await File(tgzPath).exists()) await File(tgzPath).delete(); } catch (_) {}

    // Metodo 2: Termux bootstrap zip (~30 MB)
    if (!extracted) {
      _logMsg('Descargando Termux bootstrap (~30 MB)...');
      _statusMessage = 'Descargando Termux bootstrap...'; notifyListeners();
      final arch = await getArchitecture();
      final aMap = {'aarch64': 'aarch64', 'arm64': 'aarch64', 'armv7': 'arm', 'x86_64': 'x86_64'};
      final a = aMap[arch] ?? 'aarch64';
      final url = 'https://github.com/termux/termux-packages/releases/download/bootstrap-2026.06.14-r1%2Bapt.android-7/bootstrap-$a.zip';
      final zipPath = '$appDir/termux-bootstrap.zip';
      try {
        await _downloadFile(url, zipPath, 0.35, 0.70);
        if (await File(zipPath).length() > 1000000) {
          extracted = await _extractZip(zipPath, termuxDir);
          _logMsg('Bootstrap extraido: $extracted');
        }
      } catch (e) { _logMsg('Bootstrap error: $e'); }
      try { if (await File(zipPath).exists()) await File(zipPath).delete(); } catch (_) {}
    }

    // Metodo 3: .debs individuales 
    if (!extracted) {
      _logMsg('Fallback: .debs individuales...');
      await _installFromTermuxDebs(appDir, termuxDir);
      extracted = await File('$termuxDir/bin/nano').exists();
    }

    if (!extracted) { _logMsg('Bionic bins NO disponibles'); return; }

    // Permisos
    await _applyPermissions(termuxDir);

    _bionicInstalled = await File('$termuxDir/bin/nano').exists() && await File('$termuxDir/bin/bash').exists();
    _logMsg('Bionic bins: ${_bionicInstalled ? "OK" : "incompleta"}');
  }

  Future<bool> _extractTarGz(String src, String dest) async {
    try {
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try { final r = await Process.run(tb, ['tar', '-xzf', src, '-C', dest]).timeout(const Duration(seconds: 60));
            if (r.exitCode == 0 && await File('$dest/bin/bash').exists()) return true; } catch (_) {}
        }
      }
      final data = await File(src).readAsBytes();
      for (final entry in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(data))) {
        String n = entry.name;
        if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        final f = File('$dest/$n');
        if (n.endsWith('/')) { await f.parent.create(recursive: true); continue; }
        await f.parent.create(recursive: true);
        if (entry.isFile && entry.content.isNotEmpty) await f.writeAsBytes(entry.content as List<int>);
      }
      return true;
    } catch (e) { _logMsg('extract error: $e'); return false; }
  }

  Future<bool> _extractZip(String src, String dest) async {
    try {
      final bytes = await File(src).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        final n = entry.name;
        if (n.isEmpty) continue;
        if (n.endsWith('/')) { await Directory('$dest/$n').create(recursive: true); continue; }
        final f = File('$dest/$n');
        await f.parent.create(recursive: true);
        if (entry.isFile) await f.writeAsBytes(entry.content as List<int>);
      }
      _logMsg('Zip extraido: ${archive.length} entradas');
      return true;
    } catch (e) { _logMsg('extract zip error: $e'); return false; }
  }

  Future<void> _applyPermissions(String termuxDir) async {
    try {
      for (final dir in ['bin', 'libexec', 'lib']) {
        try { await for (final f in Directory('$termuxDir/$dir').list()) { if (f is File) try { await Process.run('chmod', ['+x', f.path]); } catch (_) {} } } catch (_) {}
      }
    } catch (e) { _logMsg('Permisos: $e'); }
  }

  Future<void> _installFromTermuxDebs(String appDir, String termuxDir) async {
    final arch = await getArchitecture();
    final ext = arch == 'aarch64' ? 'aarch64' : 'arm';
    try {
      _logMsg('Descargando indice Termux...');
      final idxUrl = 'https://packages.termux.org/apt/termux-main/dists/stable/main/binary-$ext/Packages.gz';
      await _downloadFile(idxUrl, '$appDir/Packages.gz', 0.50, 0.55);
      final data = gzip.decode(await File('$appDir/Packages.gz').readAsBytes());
      Map<String, String> debs = {};
      String cn = '', fn = '';
      for (final line in String.fromCharCodes(data).split('\n')) {
        if (line.startsWith('Package:')) cn = line.substring(8).trim();
        else if (line.startsWith('Filename:')) fn = line.substring(9).trim();
        else if (line.isEmpty && cn.isNotEmpty && fn.isNotEmpty) {
          if (['bash', 'nano', 'openssh', 'libandroid-support', 'libcrypt', 'zlib', 'ca-certificates'].contains(cn))
            debs[cn] = 'https://packages.termux.org/apt/termux-main/$fn';
          cn = ''; fn = '';
        }
      }
      try { await File('$appDir/Packages.gz').delete(); } catch (_) {}
      _logMsg('${debs.length} paquetes en Termux');
      int ok = 0;
      for (final e in debs.entries) {
        try {
          final dp = '$appDir/${e.key}.deb';
          await _downloadFile(e.value, dp, 0.55, 0.70);
          if (await _extractDeb(dp, termuxDir)) ok++;
          try { await File(dp).delete(); } catch (_) {}
        } catch (ex) { _logMsg('${e.key}: $ex'); }
      }
      _logMsg('Debs: $ok/${debs.length}');
    } catch (e) { _logMsg('Termux index: $e'); }
  }

  Future<bool> _extractDeb(String debPath, String dest) async {
    try {
      final data = await File(debPath).readAsBytes();
      if (data.length < 8 || String.fromCharCodes(data.sublist(0, 8)) != '!<arch>\n') return false;
      List<int>? xzData;
      int pos = 8;
      while (pos + 60 <= data.length) {
        int nend = pos + 16;
        while (nend > pos && data[nend - 1] == 0x20) nend--;
        final name = String.fromCharCodes(data.sublist(pos, nend)).trim().replaceAll('/', '');
        final sz = int.tryParse(String.fromCharCodes(data.sublist(pos + 48, pos + 58)).trim()) ?? 0;
        if (name == 'data.tar.xz') { xzData = data.sublist(pos + 60, pos + 60 + sz); break; }
        if (sz == 0) break;
        pos += 60 + sz + (sz % 2);
      }
      if (xzData == null || xzData.isEmpty) return false;

      // xz decompression via toybox/toolbox/busybox
      for (final xb in ['/system/bin/toybox', '/system/bin/toolbox', '/system/bin/busybox']) {
        if (await File(xb).exists()) {
          try {
            final r = await Process.run(xb, ['xz', '-d'], input: xzData).timeout(const Duration(seconds: 30));
            if (r.exitCode == 0 && (r.stdout as List<int>).isNotEmpty) {
              final tar = TarDecoder().decodeBytes(r.stdout as List<int>);
              for (final e in tar) {
                String n = e.name; if (n.startsWith('./')) n = n.substring(2);
                if (n.isEmpty || n == '.') continue;
                final f = File('$dest/$n');
                if (n.endsWith('/')) { await f.parent.create(recursive: true); continue; }
                await f.parent.create(recursive: true);
                if (e.isFile && e.content.isNotEmpty) await f.writeAsBytes(e.content as List<int>);
              }
              return true;
            }
          } catch (_) {}
        }
      }

      // Fallback: tar -xJf (toybox Android 10+)
      final xf = '$debPath.data.tar.xz';
      await File(xf).writeAsBytes(xzData);
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try { final r = await Process.run(tb, ['tar', '-xJf', xf, '-C', dest]).timeout(const Duration(seconds: 60));
            if (r.exitCode == 0) { try { await File(xf).delete(); } catch (_) {} return true; } } catch (_) {}
        }
      }
      try { await File(xf).delete(); } catch (_) {}
      return false;
    } catch (e) { _logMsg('extract deb: $e'); return false; }
  }

  Future<void> _setupBionicSsh(String appDir) async {
    final termuxDir = '$appDir/termux';
    _logMsg('Configurando SSH bionic...');
    try {
      await Directory('$termuxDir/etc/ssh').create(recursive: true);
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (!await File(kf).exists()) {
          try { _logMsg('Generando key $key...');
            await Process.run('$termuxDir/bin/ssh-keygen', ['-t', key, '-f', kf, '-N', '', '-q'],
              environment: {'LD_LIBRARY_PATH': '$termuxDir/lib'}).timeout(const Duration(seconds: 30));
          } catch (e) { _logMsg('Key error: $e'); }
        }
      }
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString('''Port 2222
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
Subsystem sftp $termuxDir/libexec/sftp-server
HostKey $termuxDir/etc/ssh/ssh_host_rsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ecdsa_key
HostKey $termuxDir/etc/ssh/ssh_host_ed25519_key
''');
      _logMsg('SSH config OK (puerto 2222)');
    } catch (e) { _logMsg('SSH error: $e'); }
  }

  // ══════════════════════════════════════════════
  // APK MANAGEMENT
  // ══════════════════════════════════════════════
  Future<void> refreshApkIndex() async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    await _refreshApkIndex(rootfs);
  }
  List<Map<String, String>> searchPackages(String query, {int limit = 50}) {
    final r = <Map<String, String>>[]; final q = query.toLowerCase();
    for (final e in _apkIndex.entries) { if (e.key.toLowerCase().contains(q)) { r.add({'name': e.key, 'version': e.value}); if (r.length >= limit) break; } }
    return r;
  }
  Future<bool> installApk(String pkgName) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final ver = _apkIndex[pkgName];
    if (ver == null) { _logMsg('$pkgName no encontrado'); return false; }
    final ok = await _installApk(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }
  Future<bool> removeApk(String pkgName) async { _installedPkgs.remove(pkgName); return true; }
  List<Map<String, String>> listInstalledPackages() => _installedPkgs.map((n) => {'name': n, 'version': _apkIndex[n] ?? '?'}).toList();

  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture(); _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes');
  }
  Future<Map<String, String>> _getApkVersions(String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/APKINDEX.tar.gz';
    final path = '$rootfs/../APKINDEX.tar.gz';
    if (!await File(path).exists()) { try { await _downloadFile(url, path, 0.78, 0.80); } catch (e) { return {}; } }
    try {
      final data = await File(path).readAsBytes();
      final idx = _extractFileFromTar(GZipDecoder().decodeBytes(data), 'APKINDEX');
      if (idx == null) return {};
      final r = <String, String>{}; String cn = '', cv = '';
      for (final l in idx.split('\n')) {
        if (l.startsWith('P:')) cn = l.substring(2).trim();
        else if (l.startsWith('V:')) cv = l.substring(2).trim();
        else if (l.isEmpty && cn.isNotEmpty) { r[cn] = cv; cn = ''; cv = ''; }
      }
      return r;
    } catch (e) { return {}; }
  }
  String? _extractFileFromTar(List<int> d, String fn) {
    int p = 0;
    while (p + 512 <= d.length) {
      if (d[p] == 0) break;
      final ne = d.indexOf(0, p); if (ne < 0 || ne - p > 100) break;
      final n = String.fromCharCodes(d.sublist(p, ne));
      if (n == fn) {
        final sz = int.tryParse(String.fromCharCodes(d.sublist(p + 124, p + 136)).split('\x00')[0].trim(), radix: 8) ?? 0;
        return String.fromCharCodes(d.sublist(p + 512, p + 512 + sz));
      }
      final sz = int.tryParse(String.fromCharCodes(d.sublist(p + 124, p + 136)).split('\x00')[0].trim(), radix: 8) ?? 0;
      p += 512 + (((sz + 511) ~/ 512) * 512);
    }
    return null;
  }
  Future<bool> _installApk(String pkg, String ver, String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/$pkg-$ver.apk';
    final apkPath = '$rootfs/../$pkg-$ver.apk';
    try {
      if (!await File(apkPath).exists()) { _logMsg('Descargando: $pkg-$ver'); await _downloadFile(url, apkPath, 0.82, 0.90); }
      final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(apkPath).readAsBytes()));
      int files = 0;
      for (final e in tar) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.' || n.startsWith('.')) continue;
        if (n.endsWith('/')) { await Directory('$rootfs/$n').create(recursive: true); files++; continue; }
        if (n.contains('.pre-install') || n.contains('.post-install') || n.contains('.trigger')) continue;
        final t = File('$rootfs/$n'); await t.parent.create(recursive: true);
        if (e.isSymbolicLink && (e.symbolicLink ?? '').isNotEmpty) {
          final lt = e.symbolicLink!;
          if (lt.startsWith('/')) {
            final rt = File('$rootfs$lt');
            if (await rt.exists() && await rt.length() > 0) {
              try { if (await Link(t.path).exists()) await Link(t.path).delete(); await t.writeAsBytes(await rt.readAsBytes()); files++; } catch (_) {}
            }
          }
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) {
          await t.writeAsBytes(e.content as List<int>);
          try { if (e.mode != null && (e.mode! & 0x49) != 0) await Process.run('chmod', ['+x', t.path]); } catch (_) {}
          files++;
        }
      }
      _logMsg('$pkg-$ver: $files archivos');
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) { _logMsg('Error $pkg: $e'); return false; }
  }

  // ══════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════
  Future<void> _downloadFile(String url, String path, double sw, double ew) async {
    final c = HttpClient();
    try {
      _logMsg('Download: $url');
      final req = await c.getUrl(Uri.parse(url));
      final resp = await req.close();
      _logMsg('HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final total = resp.contentLength; int recv = 0;
      final sink = File(path).openWrite();
      await for (final chunk in resp) {
        sink.add(chunk); recv += chunk.length;
        if (total > 0) { _downloadProgress = sw + (recv / total) * (ew - sw); if (recv % (1024 * 256) < chunk.length) notifyListeners(); }
      }
      await sink.flush(); await sink.close(); _logMsg('OK: $recv bytes');
    } finally { c.close(); }
  }

  Future<bool> _setupFromAsset(String rootfs) async {
    try {
      if (!(await rootBundle.loadString('AssetManifest.json')).contains('assets/rootfs.tar.gz')) return false;
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      await File('${await _appDir}/cached_rootfs.tar.gz').writeAsBytes(data.buffer.asUint8List());
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try { final r = await Process.run(tb, ['tar', '-xzf', '${await _appDir}/cached_rootfs.tar.gz', '-C', rootfs]).timeout(const Duration(seconds: 180));
            if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0) return true; } catch (_) {}
        }
      }
      return _extractTarDart('${await _appDir}/cached_rootfs.tar.gz', rootfs);
    } catch (e) { return false; }
  }
  Future<bool> _extractTarDart(String tgz, String rootfs) async {
    try {
      for (final e in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(tgz).readAsBytes()))) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        if (n.endsWith('/')) { await Directory('$rootfs/$n').create(recursive: true); continue; }
        await Directory('$rootfs/$n').parent.create(recursive: true);
        if (e.isSymbolicLink && (e.symbolicLink ?? '').startsWith('/')) {
          try { final r = File('$rootfs${e.symbolicLink}'); if (await r.exists() && await r.length() > 0) { if (await Link('$rootfs/$n').exists()) await Link('$rootfs/$n').delete(); await File('$rootfs/$n').writeAsBytes(await r.readAsBytes()); } } catch (_) {}
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) await File('$rootfs/$n').writeAsBytes(e.content);
      }
      return true;
    } catch (e) { return false; }
  }
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    final tgz = '$appDir/rootfs.tar.gz';
    if (!await File(tgz).exists()) return false;
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try { final r = await Process.run(tb, ['tar', '-xzf', tgz, '-C', rootfs]).timeout(const Duration(seconds: 180));
          if (r.exitCode == 0 && await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0) return true; } catch (_) {}
      }
    }
    return _extractTarDart(tgz, rootfs);
  }
  Future<void> _fixHardlinks(String rootfs) async {
    int n = 0;
    final bb = File('$rootfs/bin/busybox');
    List<int>? d; if (await bb.exists() && await bb.length() > 0) d = await bb.readAsBytes();
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin']) {
      try { await for (final e in Directory('$rootfs$dir').list(followLinks: false)) { if (e is File && await e.length() == 0 && d != null) { await e.writeAsBytes(d); n++; } } } catch (_) {}
    }
    if (d != null) { final sh = File('$rootfs/bin/sh'); if (!await sh.exists() || await sh.length() == 0) { try { await sh.writeAsBytes(d); n++; } catch (_) {} } }
    _logMsg('Hardlinks: $n');
  }
  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    int n = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      try { await for (final e in Directory('$rootfs$dir').list(followLinks: false)) {
        if (e is Link) { try { final t = await e.target(); if (t.startsWith('/')) { final r = File('$rootfs$t'); if (await r.exists() && await r.length() > 0) { try { await e.delete(); } catch (_) {} await File(e.path).writeAsBytes(await r.readAsBytes()); n++; } } } catch (_) {} } } } catch (_) {}
    }
    _logMsg('Symlinks: $n');
  }

  Future<void> resetEnvironment() async {
    final d = await _appDir;
    try { await Directory(d).delete(recursive: true); } catch (_) {}
    _initialized = false; _rootfsPath = null; _apkIndex = {}; _installedPkgs.clear(); _bionicInstalled = false;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado'); notifyListeners();
  }
}
DART
echo -e "  ${GREEN}✓${NC} proot_service.dart"

# terminal_service.dart
cat > lib/services/terminal_service.dart << 'DART'
import 'package:flutter/foundation.dart';
import 'proot_service.dart';

class TerminalLine {
  final String text;
  final bool isInput;
  final bool isError;
  TerminalLine(this.text, {this.isInput = false, this.isError = false});
}

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [];
  bool _running = false;
  String _currentDir = '~';
  bool _linuxMode = false;

  List<TerminalLine> get lines => List.unmodifiable(_lines);
  bool get running => _running;
  String get currentDir => _currentDir;
  bool get linuxMode => _linuxMode;

  void toggleMode() {
    _linuxMode = !_linuxMode;
    _lines.add(TerminalLine('[Modo: ${_linuxMode ? "Linux Container" : "Shell Local"}]', isInput: false));
    notifyListeners();
  }

  Future<void> executeCommand(String command) async {
    if (command.trim().isEmpty) {
      _lines.add(TerminalLine('', isInput: false));
      notifyListeners();
      return;
    }

    _running = true;
    _lines.add(TerminalLine('\$ $command', isInput: true));
    notifyListeners();

    final proot = ProotService();
    String output;

    if (_linuxMode && proot.initialized) {
      // Modo Linux Container: procura ejecutar dentro del rootfs
      output = await proot.runCommand(command, timeout: const Duration(seconds: 30));
    } else {
      // Modo Shell Local: ejecutar con PATH ajustado
      try {
        final rootfs = proot.rootfsPath ?? '';
        final termuxDir = '${(await _getDocDir())}/linux_container/termux';
        String path = '/system/bin:/system/xbin';
        if (proot.hasBionic) path = '$termuxDir/bin:$path';
        if (rootfs.isNotEmpty) path += ':$rootfs/usr/local/sbin:$rootfs/usr/local/bin:$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin';

        final env = <String, String>{'PATH': path, 'HOME': '/root', 'TERM': 'xterm-256color'};
        if (proot.hasBionic) env['LD_LIBRARY_PATH'] = '$termuxDir/lib';
        if (proot.hasBionic) env['PREFIX'] = termuxDir;

        final r = await Process.run('/system/bin/sh', ['-c', command],
            environment: env).timeout(const Duration(seconds: 30));
        output = (r.stdout as String) + ((r.stderr as String).isNotEmpty ? '\n${r.stderr}' : '');
      } catch (e) {
        output = '[Error] $e';
      }
    }

    if (output.trim().isNotEmpty) {
      for (final line in output.split('\n')) {
        _lines.add(TerminalLine(line, isInput: false, isError: line.contains('rror') || line.contains('denied')));
      }
    }

    _running = false;
    notifyListeners();
  }

  Future<String> _getDocDir() async {
    final p = await getApplicationDocumentsDirectory();
    return p.path;
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}
// Necesario para Process
import 'dart:io';
import 'package:path_provider/path_provider.dart';
DART
echo -e "  ${GREEN}✓${NC} terminal_service.dart"

# Resto de servicios
cat > lib/services/network_service.dart << 'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'proot_service.dart';

class NetworkService extends ChangeNotifier {
  final List<NetworkResult> _results = [];
  bool _running = false;

  List<NetworkResult> get results => List.unmodifiable(_results);
  bool get running => _running;

  Future<void> runPing(String host, {int count = 4}) async {
    _running = true; notifyListeners();
    final proot = ProotService();
    String cmd;
    if (proot.hasBionic) {
      cmd = 'ping -c $count -W 5 $host 2>&1 || echo "Ping fail"';
    } else {
      cmd = '/system/bin/sh -c "ping -c $count $host 2>&1" 2>/dev/null || toybox ping $host 2>&1 || echo ping $host';
    }
    final sw = Stopwatch()..start();
    final out = await proot.runCommand(cmd, timeout: const Duration(seconds: 30));
    sw.stop();
    _results.insert(0, NetworkResult('ping $host', out, 0, sw.elapsed));
    _running = false; notifyListeners();
  }

  Future<void> runCurl(String url) async {
    _running = true; notifyListeners();
    final proot = ProotService();
    String cmd;
    if (proot.hasBionic) {
      cmd = 'curl -sI --connect-timeout 10 "$url" 2>&1 || echo "Curl fail"';
    } else {
      cmd = '/system/bin/sh -c "curl -sI $url 2>&1" 2>/dev/null || wget -q --timeout=10 --spider "$url" 2>&1 || echo "HTTP check: $url"';
    }
    final sw = Stopwatch()..start();
    final out = await proot.runCommand(cmd, timeout: const Duration(seconds: 30));
    sw.stop();
    _results.insert(0, NetworkResult('curl $url', out, 0, sw.elapsed));
    _running = false; notifyListeners();
  }

  Future<void> runDnsLookup(String host) async {
    _running = true; notifyListeners();
    final proot = ProotService();
    final cmd = 'nslookup $host 2>&1 || echo "nslookup unavailable"';
    final sw = Stopwatch()..start();
    final out = await proot.runCommand(cmd, timeout: const Duration(seconds: 15));
    sw.stop();
    _results.insert(0, NetworkResult('dns $host', out, 0, sw.elapsed));
    _running = false; notifyListeners();
  }

  Future<void> runTraceroute(String host) async {
    _running = true; notifyListeners();
    final proot = ProotService();
    final cmd = 'traceroute $host 2>&1 || tracepath $host 2>&1 || echo "traceroute unavailable"';
    final sw = Stopwatch()..start();
    final out = await proot.runCommand(cmd, timeout: const Duration(seconds: 30));
    sw.stop();
    _results.insert(0, NetworkResult('traceroute $host', out, 0, sw.elapsed));
    _running = false; notifyListeners();
  }

  void clear() { _results.clear(); notifyListeners(); }
}

class NetworkResult {
  final String command;
  final String output;
  final int exitCode;
  final Duration duration;
  NetworkResult(this.command, this.output, this.exitCode, this.duration);
}
DART
echo -e "  ${GREEN}✓${NC} network_service.dart"

# SSH service
cat > lib/services/ssh_service.dart << 'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proot_service.dart';

class SshService extends ChangeNotifier {
  Process? _sshdProcess;
  bool _running = false;
  String _status = 'Detenido';
  String _output = '';

  bool get running => _running;
  String get status => _status;
  String get output => _output;

  Future<bool> startSsh() async {
    if (_running) { _status = 'SSH ya en ejecucion'; notifyListeners(); return true; }
    final proot = ProotService();
    final termuxDir = '${await _appDir}/termux';

    if (!proot.hasBionic) {
      _status = 'SSH no disponible: sin bionic';
      _output = 'Se requieren binarios nativos (bionic). Pulsa Setup Linux.';
      notifyListeners();
      return false;
    }

    try {
      _status = 'Iniciando SSH...';
      notifyListeners();

      // Generar keys si no existen
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (!await File(kf).exists()) {
          try {
            await Process.run('$termuxDir/bin/ssh-keygen', ['-t', key, '-f', kf, '-N', '', '-q'],
              environment: {'LD_LIBRARY_PATH': '$termuxDir/lib'}).timeout(const Duration(seconds: 30));
          } catch (e) { _output += 'Key error: $e\n'; }
        }
      }

      // Iniciar sshd
      _sshdProcess = await Process.start(
        '$termuxDir/bin/sshd', ['-D', '-f', '$termuxDir/etc/ssh/sshd_config', '-p', '2222'],
        environment: {
          'LD_LIBRARY_PATH': '$termuxDir/lib',
          'PATH': '$termuxDir/bin:/system/bin',
          'PREFIX': termuxDir,
        },
      );

      _running = true;
      _status = 'SSH activo en puerto 2222';
      _output = 'Usuario: root\nPassword: linux\nPuerto: 2222\n';
      _output += 'Comando: ssh root@<IP> -p 2222\n';

      // Leer stderr
      _sshdProcess!.stderr.transform(utf8.decoder).listen((data) {
        _output += data;
        notifyListeners();
      });

      _sshdProcess!.exitCode.then((code) {
        _running = false;
        _status = 'SSH detenido (exit: $code)';
        notifyListeners();
      });

      notifyListeners();
      return true;
    } catch (e) {
      _status = 'Error SSH: $e';
      _output += 'Error: $e\n';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopSsh() async {
    if (_sshdProcess != null) {
      _sshdProcess!.kill();
      _sshdProcess = null;
    }
    _running = false;
    _status = 'SSH detenido';
    notifyListeners();
  }

  Future<String> _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}

import 'package:path_provider/path_provider.dart';
DART
echo -e "  ${GREEN}✓${NC} ssh_service.dart"

# opencloud_service
cat > lib/services/opencloud_service.dart << 'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proot_service.dart';

class OpenCloudService extends ChangeNotifier {
  bool _installed = false;
  bool _running = false;
  String _status = 'No instalado';
  String _output = '';

  bool get installed => _installed;
  bool get running => _running;
  String get status => _status;
  String get output => _output;

  Future<void> installOpenCloud() async {
    _status = 'Instalando OpenCloud...';
    _output = 'Iniciando instalacion...\n';
    notifyListeners();

    final proot = ProotService();
    final rootfs = proot.rootfsPath ?? '${await _appDir}/rootfs';
    final termuxDir = '${await _appDir}/termux';

    if (!proot.hasBionic) {
      _output += 'ERROR: Se requieren binarios nativos. Pulsa Setup Linux primero.\n';
      _status = 'Error: sin bionic';
      notifyListeners();
      return;
    }

    try {
      // Instalar Apache + PHP + MariaDB via Alpine APK (datos)
      for (final pkg in ['apache2', 'php', 'php-mysqli', 'mariadb', 'mariadb-client']) {
        _output += 'Instalando $pkg...\n';
        await proot.installApk(pkg);
        notifyListeners();
      }

      // Configurar basica
      _output += 'Configurando servicios...\n';
      await Directory('$rootfs/var/www/localhost/htdocs').create(recursive: true);
      await File('$rootfs/var/www/localhost/htdocs/index.html').writeAsString(
        '<html><body><h1>OpenCloud en Linux Container</h1>'
        '<p>Servidor web funcionando en Android via Alpine Linux!</p>'
        '<p>Puerto: 8080</p></body></html>'
      );

      _installed = true;
      _status = 'OpenCloud instalado (puerto 8080)';
      _output += 'Instalacion completada.\n';
      _output += 'Web: http://localhost:8080\n';
      notifyListeners();
    } catch (e) {
      _status = 'Error: $e';
      _output += 'Error: $e\n';
      notifyListeners();
    }
  }

  Future<void> startOpenCloud() async {
    _status = 'Iniciando...';
    _output = 'Servicios no implementados aun...\n';
    notifyListeners();
  }

  Future<void> stopOpenCloud() async {
    _running = false;
    _status = 'Detenido';
    notifyListeners();
  }

  Future<String> _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}

import 'package:path_provider/path_provider.dart';
DART
echo -e "  ${GREEN}✓${NC} opencloud_service.dart"

echo -e "  ${GREEN}✓${NC} Servicios escritos"

# Escribir screens
cat > lib/screens/home_screen.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/proot_service.dart';
import 'terminal_screen.dart';
import 'packages_screen.dart';
import 'ssh_screen.dart';
import 'network_screen.dart';
import 'opencloud_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProotService>().checkEnvironment();
    });
  }

  void _showLogDialog(ProotService proot) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          children: [
            AppBar(
              title: const Text('Log de Setup'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  child: Consumer<ProotService>(
                    builder: (ctx, proot, _) => SelectableText(
                      proot.logText,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Linux Container'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Ver Log',
            onPressed: () => _showLogDialog(context.read<ProotService>()),
          ),
        ],
      ),
      body: Consumer<ProotService>(
        builder: (context, proot, _) {
          return RefreshIndicator(
            onRefresh: () => proot.checkEnvironment(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.colorScheme.primaryContainer, theme.colorScheme.secondaryContainer],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.terminal_rounded, size: 48, color: theme.colorScheme.onPrimaryContainer),
                      const SizedBox(height: 12),
                      Text('Terminal Linux', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
                      const SizedBox(height: 8),
                      Text(
                        proot.initialized ? 'Listo para usar' :
                        proot.isDownloading ? '${(proot.downloadProgress * 100).toInt()}% - ${proot.statusMessage}' :
                        proot.statusMessage,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)),
                      ),
                      if (!proot.initialized && !proot.isDownloading) ...[
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => proot.setupEnvironment(),
                          icon: const Icon(Icons.download),
                          label: const Text('Setup Linux'),
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
                        ),
                        const SizedBox(height: 8),
                        Text('Requiere ~3MB Alpine + ~30MB Termux bootstrap',
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.6))),
                      ],
                      if (proot.isDownloading) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: proot.downloadProgress, backgroundColor: Colors.white24),
                        const SizedBox(height: 8),
                        Text(proot.statusMessage, style: TextStyle(color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7), fontSize: 12)),
                      ],
                      if (proot.initialized && proot.hasBionic) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                          child: const Text('✓ Bionic activo (nano, sshd, bash)', style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('Accesos Rápidos', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),

                _buildCard(context, Icons.terminal, 'Terminal', 'Shell interactivo con apk', Colors.teal, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TerminalScreen()))),
                _buildCard(context, Icons.inventory_2, 'Gestor de Paquetes', 'Instalar/eliminar paquetes apk', Colors.indigo, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PackagesScreen()))),
                _buildCard(context, Icons.lan_rounded, 'Servidor SSH', 'Acceso remoto seguro (puerto 2222)', Colors.orange, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SshScreen()))),
                _buildCard(context, Icons.wifi_rounded, 'Networking', 'Ping, HTTP, DNS, traceroute', Colors.blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkScreen()))),
                _buildCard(context, Icons.cloud_rounded, 'OpenCloud', 'Nube privada (Apache+PHP+MariaDB)', Colors.deepPurple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OpenCloudScreen()))),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(BuildContext context, IconData icon, String title, String subtitle, Color color, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(elevation: 0, clipBehavior: Clip.antiAlias, child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: color, size: 28)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ])),
          Icon(Icons.arrow_forward_ios_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
        ]))),
      )),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} home_screen.dart"

# Escribir terminal_screen.dart
cat > lib/screens/terminal_screen.dart << 'DART'
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/terminal_service.dart';
import '../services/proot_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  late TerminalService _term;

  @override
  void initState() {
    super.initState();
    _term = TerminalService();
    if (_term.lines.isEmpty) {
      _term.lines.add(TerminalLine('[Sistema listo] Escribe comandos o cambia modo con el icono.', isInput: false));
      _term.lines.add(TerminalLine('', isInput: false));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _execute(String cmd) {
    if (cmd.trim().isEmpty) return;
    _term.executeCommand(cmd);
    _controller.clear();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          Text(_term.linuxMode ? 'Linux' : 'Shell', style: const TextStyle(fontSize: 12)),
          IconButton(
            icon: Icon(_term.linuxMode ? Icons.article : Icons.terminal),
            tooltip: 'Cambiar modo',
            onPressed: () => _term.toggleMode(),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => _term.clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Output
          Expanded(
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.all(8),
              child: Consumer<TerminalService>(
                builder: (ctx, term, _) {
                  return ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: term.lines.length,
                    itemBuilder: (ctx, i) {
                      final line = term.lines[i];
                      Color color;
                      if (line.isInput) color = Colors.greenAccent;
                      else if (line.isError) color = Colors.redAccent;
                      else color = const Color(0xFFE0E0E0);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line.text,
                          style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 12, height: 1.4),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // Input
          Container(
            padding: const EdgeInsets.all(8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Text('\$ ', style: TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 14)),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration.collapsed(hintText: 'Escribe un comando...'),
                    onSubmitted: _execute,
                    enabled: !_term.running,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _term.running ? null : () => _execute(_controller.text),
                  tooltip: 'Ejecutar',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} terminal_screen.dart"

# Modelos
mkdir -p lib/models
cat > lib/models/package_model.dart << 'DART'
class PackageModel {
  final String name;
  final String version;
  final String description;
  final bool installed;
  PackageModel({required this.name, required this.version, required this.description, this.installed = false});
}
DART
echo -e "  ${GREEN}✓${NC} models"

# Widgets
mkdir -p lib/widgets
cat > lib/widgets/package_tile.dart << 'DART'
import 'package:flutter/material.dart';
import '../models/package_model.dart';

class PackageTile extends StatelessWidget {
  final PackageModel package;
  final VoidCallback? onInstall;
  final VoidCallback? onRemove;
  const PackageTile({super.key, required this.package, this.onInstall, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(elevation: 0, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: ListTile(
      leading: Icon(package.installed ? Icons.check_circle : Icons.package_2, color: package.installed ? Colors.green : theme.colorScheme.primary),
      title: Text(package.name, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
      subtitle: Text('${package.version}${package.installed ? " [instalado]" : ""}', style: const TextStyle(fontSize: 12)),
      trailing: package.installed
        ? IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: onRemove)
        : IconButton(icon: const Icon(Icons.download), onPressed: onInstall),
    ));
  }
}
DART

cat > lib/widgets/status_card.dart << 'DART'
import 'package:flutter/material.dart';

class StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const StatusCard({super.key, required this.icon, required this.title, required this.subtitle, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(elevation: 0, clipBehavior: Clip.antiAlias, child: InkWell(
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: color, size: 28)),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ])),
        const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey),
      ])),
    ));
  }
}
DART
echo -e "  ${GREEN}✓${NC} widgets"

# Screens que faltan
cat > lib/screens/packages_screen.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/package_service.dart';
import '../services/proot_service.dart';
import '../widgets/package_tile.dart';

class PackagesScreen extends StatefulWidget {
  const PackagesScreen({super.key});
  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final PackageService _pkgService = PackageService();
  bool _loading = false;
  String _output = '';
  String _status = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() { _loading = true; _output = 'Buscando...'; });
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) { setState(() { _output = 'Introduce un termino de busqueda'; _loading = false; }); return; }
    final proot = context.read<ProotService>();
    if (proot.apkIndex.isEmpty) {
      await proot.refreshApkIndex();
    }
    final results = proot.searchPackages(q);
    setState(() {
      _output = '${results.length} resultados para: $q\n\n';
      for (final r in results) {
        _output += '  ${r['name']} - ${r['version']}${proot.installedPackages.contains(r['name']) ? " [instalado]" : ""}\n';
      }
      _loading = false;
    });
  }

  Future<void> _install(String name) async {
    setState(() { _output = 'Instalando $name...'; _loading = true; });
    final proot = context.read<ProotService>();
    final ok = await proot.installApk(name);
    setState(() { _output = ok ? '✅ $name instalado' : '❌ Error instalando $name'; _loading = false; });
  }

  Future<void> _remove(String name) async {
    setState(() { _output = 'Eliminando $name...'; _loading = true; });
    final proot = context.read<ProotService>();
    final ok = await proot.removeApk(name);
    setState(() { _output = ok ? '✅ $name eliminado' : '❌ Error eliminando $name'; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Gestor de Paquetes')),
      body: Column(children: [
        if (!proot.hasBionic)
          Container(
            padding: const EdgeInsets.all(8), margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
            child: const Row(children: [Icon(Icons.info, color: Colors.orange, size: 16), SizedBox(width: 8),
              Expanded(child: Text('Los binarios APK (musl) no ejecutan en Android sin bionic. Pulsa Setup Linux.', style: TextStyle(fontSize: 11))),
            ]),
          ),
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: TextField(controller: _searchCtrl, decoration: const InputDecoration(hintText: 'Buscar paquete...', prefixIcon: Icon(Icons.search), isDense: true),
            onSubmitted: (_) => _search())),
          const SizedBox(width: 8),
          FilledButton.tonal(onPressed: _search, child: const Text('Buscar')),
          const SizedBox(width: 4),
          OutlinedButton(onPressed: () async { await proot.refreshApkIndex(); _search(); }, child: const Text('Sync')),
        ])),
        if (_loading) const LinearProgressIndicator(),
        Expanded(child: Container(
          color: Colors.black, padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(child: SelectableText(_output.isNotEmpty ? _output : 'Usa el buscador para encontrar paquetes\n\nEj: apk search nano, apk search ssh',
            style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12, height: 1.4))),
        )),
      ]),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} packages_screen.dart"

cat > lib/screens/ssh_screen.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ssh_service.dart';
import '../services/proot_service.dart';

class SshScreen extends StatefulWidget {
  const SshScreen({super.key});
  @override
  State<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends State<SshScreen> {
  final SshService _ssh = SshService();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Servidor SSH')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Icon(Icons.lan_rounded, size: 64, color: _ssh.running ? Colors.green : Colors.grey),
          const SizedBox(height: 12),
          Text('SSH Server', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: _ssh.running ? Colors.green.withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
            child: Text(_ssh.running ? 'Puerto 2222 - ACTIVO' : 'Detenido', style: TextStyle(color: _ssh.running ? Colors.greenAccent : Colors.grey, fontSize: 12))),
        ]))),
        const SizedBox(height: 16),
        if (!proot.hasBionic)
          Card(color: Colors.orange.withValues(alpha: 0.1), child: const Padding(padding: EdgeInsets.all(12), child: Text('SSH requiere binarios nativos (bionic). Pulsa Setup Linux en la pantalla principal primero.', style: TextStyle(fontSize: 12)))),
        if (_loading) const LinearProgressIndicator(),
        Row(children: [
          Expanded(child: FilledButton.icon(
            onPressed: (proot.hasBionic && !_loading) ? () async { setState(() => _loading = true); await _ssh.startSsh(); setState(() => _loading = false); } : null,
            icon: const Icon(Icons.play_arrow), label: const Text('Iniciar SSH'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
            onPressed: _ssh.running ? () async { await _ssh.stopSsh(); setState(() {}); } : null,
            icon: const Icon(Icons.stop), label: const Text('Detener'))),
        ]),
        const SizedBox(height: 16),
        if (_ssh.output.isNotEmpty) ...[
          Text('Consola:', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.all(8), color: Colors.black, child: SelectableText(_ssh.output,
            style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11, height: 1.4))),
        ],
      ]),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} ssh_screen.dart"

cat > lib/screens/network_screen.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/network_service.dart';
import '../services/proot_service.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});
  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final TextEditingController _hostCtrl = TextEditingController(text: 'google.com');
  final NetworkService _net = NetworkService();
  bool _loading = false;

  @override
  void dispose() { _hostCtrl.dispose(); super.dispose(); }

  Future<void> _run(String action) async {
    if (_loading) return;
    setState(() => _loading = true);
    final host = _hostCtrl.text.trim();
    switch (action) {
      case 'ping': await _net.runPing(host); break;
      case 'curl': await _net.runCurl('https://$host'); break;
      case 'dns': await _net.runDnsLookup(host); break;
      case 'trace': await _net.runTraceroute(host); break;
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Networking')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: TextField(controller: _hostCtrl, decoration: const InputDecoration(hintText: 'host', prefixIcon: Icon(Icons.language), isDense: true))),
        if (_loading) const LinearProgressIndicator(),
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            ActionChip(avatar: const Icon(Icons.wifi, size: 16), label: const Text('Ping'), onPressed: () => _run('ping')),
            const SizedBox(width: 4),
            ActionChip(avatar: const Icon(Icons.http, size: 16), label: const Text('HTTP'), onPressed: () => _run('curl')),
            const SizedBox(width: 4),
            ActionChip(avatar: const Icon(Icons.dns, size: 16), label: const Text('DNS'), onPressed: () => _run('dns')),
            const SizedBox(width: 4),
            ActionChip(avatar: const Icon(Icons.route, size: 16), label: const Text('Trace'), onPressed: () => _run('trace')),
            const SizedBox(width: 8),
            ActionChip(avatar: const Icon(Icons.delete, size: 16), label: const Text('Clear'), onPressed: () => _net.clear()),
          ]),
        ),
        Expanded(child: Consumer<NetworkService>(builder: (ctx, net, _) {
          if (net.results.isEmpty) return const Center(child: Text('Sin resultados'));
          return ListView.builder(itemCount: net.results.length, itemBuilder: (ctx, i) {
            final r = net.results[i];
            return Card(elevation: 0, margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.command, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 4),
              Container(padding: const EdgeInsets.all(8), color: Colors.black, child: SelectableText(r.output.isNotEmpty ? r.output : '(sin output)',
                style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 10, height: 1.3))),
            ])));
          });
        })),
      ]),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} network_screen.dart"

cat > lib/screens/opencloud_screen.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/opencloud_service.dart';
import '../services/proot_service.dart';

class OpenCloudScreen extends StatefulWidget {
  const OpenCloudScreen({super.key});
  @override
  State<OpenCloudScreen> createState() => _OpenCloudScreenState();
}

class _OpenCloudScreenState extends State<OpenCloudScreen> {
  final OpenCloudService _oc = OpenCloudService();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(title: const Text('OpenCloud')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Icon(Icons.cloud_rounded, size: 64, color: _oc.installed ? Colors.deepPurple : Colors.grey),
          const SizedBox(height: 12),
          Text('OpenCloud', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(_oc.status, style: TextStyle(color: _oc.installed ? Colors.green : Colors.grey, fontSize: 12)),
        ]))),
        const SizedBox(height: 16),
        if (!proot.hasBionic)
          Card(color: Colors.orange.withValues(alpha: 0.1), child: const Padding(padding: EdgeInsets.all(12), child: Text('OpenCloud requiere binarios nativos (bionic). Pulsa Setup Linux.', style: TextStyle(fontSize: 12)))),
        if (_loading) const LinearProgressIndicator(),
        FilledButton.icon(
          onPressed: (proot.hasBionic && !_loading) ? () async { setState(() => _loading = true); await _oc.installOpenCloud(); setState(() => _loading = false); } : null,
          icon: const Icon(Icons.cloud_download), label: const Text('Instalar OpenCloud')),
        const SizedBox(height: 16),
        if (_oc.output.isNotEmpty) ...[
          Text('Consola:', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.all(8), color: Colors.black, child: SelectableText(_oc.output,
            style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11, height: 1.4))),
        ],
      ]),
    );
  }
}
DART
echo -e "  ${GREEN}✓${NC} opencloud_screen.dart"

# package_service.dart
cat > lib/services/package_service.dart << 'DART'
import '../models/package_model.dart';
import 'proot_service.dart';

class PackageService {
  final ProotService _proot = ProotService();
  List<PackageModel> _packages = [];
  bool _loading = false;
  String _output = '';
  String _status = '';

  List<PackageModel> get packages => _packages;
  bool get loading => _loading;
  String get output => _output;
  String get status => _status;

  void notify() { /* Provider callback */ }

  Future<void> updatePackages() async {
    _loading = true; _status = 'Actualizando repositorios...'; _output = ''; notify();
    await _proot.refreshApkIndex();
    _status = 'Repositorios actualizados (${_proot.apkIndex.length} paquetes)';
    _output = 'APKINDEX: ${_proot.apkIndex.length} paquetes disponibles\n';
    _loading = false; notify();
  }

  Future<void> searchPackages(String query) async {
    _loading = true; _status = 'Buscando: $query'; _output = ''; notify();
    final results = _proot.searchPackages(query);
    _packages = results.map((r) => PackageModel(name: r['name']!, version: r['version']!, description: r['version']!, installed: _proot.installedPackages.contains(r['name']))).toList();
    _output = _packages.isEmpty ? 'No se encontraron paquetes para: $query\n' : '${_packages.length} resultados para: $query\n\n${_packages.map((p) => '  ${p.name} - ${p.version}${p.installed ? " [instalado]" : ""}').join("\n")}\n';
    _status = 'Resultados para: $query'; _loading = false; notify();
  }

  Future<void> installPackage(String name) async {
    _loading = true; _status = 'Instalando $name...'; _output = 'Instalando $name...\n'; notify();
    bool ok = await _proot.installApk(name);
    _output += ok ? '✅ $name instalado correctamente\n' : '❌ Error instalando $name\n';
    _status = ok ? 'Paquete $name instalado' : 'Error instalando $name';
    _loading = false; notify();
  }

  Future<void> removePackage(String name) async {
    _loading = true; _status = 'Eliminando $name...'; _output = 'Eliminando $name...\n'; notify();
    bool ok = await _proot.removeApk(name);
    _output += ok ? '✅ $name eliminado\n' : '❌ Error eliminando $name\n';
    _status = ok ? 'Paquete $name eliminado' : 'Error eliminando $name';
    _loading = false; notify();
  }

  Future<void> listInstalled() async {
    _loading = true; _status = 'Listando paquetes instalados...';
    final installed = _proot.listInstalledPackages();
    _output = installed.isEmpty ? 'No hay paquetes instalados\n' : 'Paquetes instalados (${installed.length}):\n\n${installed.map((p) => '  ${p['name']} - ${p['version']}').join("\n")}\n';
    _status = 'Paquetes instalados'; _loading = false; notify();
  }
}
DART
echo -e "  ${GREEN}✓${NC} package_service.dart"

echo -e "  ${GREEN}✓${NC} Codigo fuente completo"
echo ""

# ─── 3. Inyectar permisos Android ───
echo -e "${YELLOW}[3/6] Inyectando permisos Android...${NC}"

python3 << 'PYTHON'
import os, xml.dom.minidom

manifest_path = 'android/app/src/main/AndroidManifest.xml'
if not os.path.exists(manifest_path):
    os.makedirs(os.path.dirname(manifest_path), exist_ok=True)

manifest = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.micloj.linux_container_app">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.READ_CONTACTS" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <application
        android:label="Linux Container"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="true"
        android:networkSecurityConfig="@xml/network_security_config"
        android:largeHeap="true"
        android:hardwareAccelerated="true">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:windowSoftInputMode="adjustResize">

            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />

            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
    </application>
</manifest>"""

with open(manifest_path, 'w') as f:
    f.write(manifest)
print(f"  Permisos inyectados en {manifest_path}")
PYTHON

# Crear network_security_config.xml
mkdir -p android/app/src/main/res/xml
cat > android/app/src/main/res/xml/network_security_config.xml << 'XML'
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
XML
echo -e "  ${GREEN}✓${NC} network_security_config.xml"

# ─── 4. Verificar dependencias ───
echo -e "\n${YELLOW}[4/6] Verificando dependencias...${NC}"
flutter pub get 2>&1 | tail -3
echo -e "  ${GREEN}✓${NC} Dependencias OK"

# ─── 5. Compilar APK ───
echo -e "\n${YELLOW}[5/6] Compilando APK...${NC}"
echo -e "  ${BLUE}Arquitectura: $(uname -m)${NC}"

# Verificar si es ARM64 (no soportado para compilacion Flutter)
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo -e "  ${YELLOW}⚠ ARM64 detectado. La compilacion local de Flutter no es compatible.${NC}"
    echo -e "  ${YELLOW}  Se usara GitHub Actions para la compilacion.${NC}"
    echo -e "  ${YELLOW}  Haciendo push a GitHub y activando CI...${NC}"
    
    # Guardar token si no existe
    if ! gh auth status 2>&1 | grep -q "active"; then
        TOKEN="${GH_TOKEN:-tu_token_aqui}"
        echo "$TOKEN" | gh auth login --with-token 2>/dev/null || echo "  gh login fallo, continuando..."
    fi
    
    # Commit y push
    git add -A 2>/dev/null
    git commit --allow-empty -m "v9.0: Build script + Termux bootstrap + bionic bins" 2>/dev/null || true
    git push origin main 2>&1 || echo "  Push fallo, se usara CI manual"
    
    # Crear tag
    git tag -f v9.0 2>/dev/null || true
    git push origin v9.0 2>&1 || echo "  Tag push fallo"
    
    echo -e "\n${BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CI activado. La APK se compilara en GitHub.${NC}"
    echo -e "${BLUE}  Ve a: https://github.com/txurtxil/LinuxContainer/actions${NC}"
    echo -e "${BLUE}  Descarga el APK de los artifacts.${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
else
    # Compilar localmente en x86_64
    flutter build apk --release --target-platform android-arm64 2>&1
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$APK_PATH" ]; then
        echo -e "  ${GREEN}✓${NC} APK generado: $APK_PATH ($(du -h "$APK_PATH" | cut -f1))"
    else
        echo -e "  ${RED}✗${NC} No se encontro APK"
        exit 1
    fi
fi

# ─── 6. Publicar Release (opcional) ───
if [ "$1" = "--release" ]; then
    echo -e "\n${YELLOW}[6/6] Publicando release en GitHub...${NC}"
    
    # Autenticar gh
    if ! gh auth status 2>&1 | grep -q "active"; then
        TOKEN="${GH_TOKEN:-tu_token_aqui}"
        echo "$TOKEN" | gh auth login --with-token 2>/dev/null || true
    fi
    
    # Verificar APK existe
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    if [ ! -f "$APK_PATH" ]; then
        # Buscar APK en otro lugar
        APK_PATH=$(find build -name "*.apk" 2>/dev/null | head -1)
    fi
    
    if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
        gh release create v9.0 "$APK_PATH" \
            --title "Linux Container v9.0" \
            --notes "## Linux Container v9.0

### ✨ Novedades
- **Termux Bootstrap**: Binarios nativos Android (bionic) para nano, sshd, bash
- **Gestor de Paquetes Alpine**: Instalacion nativa via Dart (sin apk binary)
- **Servidor SSH**: Puerto 2222, usuario root, password: linux
- **Networking**: Ping, HTTP, DNS, traceroute
- **OpenCloud**: Apache + PHP + MariaDB (Alpha)
- **Log permanente**: Boton Ver Log siempre visible
- **Material Design 3**: Tema oscuro, animaciones suaves

### 🔧 Stack
- Alpine Linux rootfs + Termux bionic bins
- Flutter 3.27.1 | Dart 3.12
- OpenSSH, Curl, Wget, Nano, Bash
- APK manager nativo en Dart

### 📦 Instalacion
1. Descarga el APK e instalalo
2. Abre la app y pulsa 'Setup Linux'
3. Espera a que se descarguen los componentes (~33 MB)
4. Usa la terminal, SSH, paquetes, etc."
        echo -e "  ${GREEN}✓${NC} Release v9.0 creada"
    else
        echo -e "  ${YELLOW}⚠ APK no encontrado para release. Compila primero en CI.${NC}"
    fi
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Linux Container v9.0 - BUILD COMPLETADO${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  Para descargar la APK:"
echo -e "  1. Ve a: ${BLUE}https://github.com/txurtxil/LinuxContainer/actions${NC}"
echo -e "  2. Abre el ultimo workflow run"
echo -e "  3. Descarga 'linux-container-apk'"
echo -e ""
echo -e "  O espera a que CI termine y descarga desde Releases:"
echo -e "  ${BLUE}https://github.com/txurtxil/LinuxContainer/releases${NC}"
echo ""
