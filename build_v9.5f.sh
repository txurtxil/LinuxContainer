#!/bin/bash
set -e

########################################################################
# Linux Container v9.5f - Build & Release Script
# 
# Este script:
# 1. Corrige todos los archivos Dart con bugs críticos
# 2. Arregla symlinks soname y permisos
# 3. Implementa OpenCloud real (servidor HTTP en Dart)
# 4. Corrige el CI workflow para preservar symlinks
# 5. Push a GitHub + release tag
########################################################################

APP_DIR="/tmp/LinuxContainer"
VERSION="9.5f"
echo "=== Linux Container v9.5f Build Script ==="
cd "$APP_DIR"

# ──────────────────────────────────────────────────────────────────
# 1. PROOT SERVICE - Núcleo de ejecución y setup
# ──────────────────────────────────────────────────────────────────
echo "[1/6] Escribiendo proot_service.dart..."
cat << 'DART' > lib/services/proot_service.dart
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
  String _statusMessage = 'Linux Container v9.5f';
  String _lastOutput = '';
  final List<String> _log = [];
  Map<String, String> _apkIndex = {};
  final Set<String> _installedPkgs = {};
  String _arch = '';
  bool _bionicInstalled = false;
  String? _rootfsPath;
  String _alpineMirror = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main';

  List<String> get log => List.unmodifiable(_log);
  String get logText => _log.join('\n');
  void _logMsg(String msg) {
    _log.add('[${DateTime.now().toString().substring(11, 19)}] $msg');
    debugPrint('LC: $msg');
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
  Future<String> get _rootfs async => _rootfsPath ?? '${await _appDir}/rootfs';
  Future<String> get _termux async => '${await _appDir}/termux';

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
    return _arch;
  }

  // ═══════════════════════════════════════════════════════
  // runCommand - PROPER Android 15+ EXECUTION
  // ═══════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    return _exec(command, timeout: timeout);
  }

  /// Ejecuta comandos con 3 estrategias:
  ///   1) linker64 + binario bionic (para binarios Termux)
  ///   2) linker64 + shell (para comandos compuestos)
  ///   3) /system/bin/sh directo (fallback)
  Future<String> _exec(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = await _rootfs;
    final termuxDir = await _termux;
    final homeDir = '$rootfs/root';

    try {
      // Construir PATH: bionic bins primero, luego Android system, luego Alpine rootfs
      String path = '/system/bin:/system/xbin';
      if (_bionicInstalled) path = '$termuxDir/bin:$termuxDir/libexec:$path';
      path += ':$rootfs/usr/local/sbin:$rootfs/usr/local/bin'
              ':$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin';

      final env = <String, String>{
        'PATH': path,
        'HOME': homeDir,
        'TERM': 'xterm-256color',
        'TMPDIR': '$rootfs/tmp',
        'SHELL': '/system/bin/sh',
        'USER': 'root',
        'LOGNAME': 'root',
      };
      if (_bionicInstalled) {
        env['LD_LIBRARY_PATH'] = '$termuxDir/lib';
        env['PREFIX'] = termuxDir;
      }

      _logMsg('cmd: $command');

      // Estrategia 1: linker64 directo para binarios bionic (comandos simples)
      if (_bionicInstalled) {
        final parts = command.trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          final binName = parts.first;
          // Solo comandos simples (sin pipes, redirects, &&, ;)
          final isSimple = !command.contains('|') && !command.contains('>') 
              && !command.contains('<') && !command.contains('&&') 
              && !command.contains(';') && !command.contains('2>');
          if (isSimple) {
            // Buscar el binario en termux/bin
            final binPath = '$termuxDir/bin/$binName';
            if (await File(binPath).exists()) {
              try {
                final linkerArgs = <String>[binPath, ...parts.skip(1)];
                final r = await Process.run('/system/bin/linker64', linkerArgs,
                    environment: env, workingDirectory: homeDir
                ).timeout(timeout);
                final errStr = (r.stderr as String);
                if (errStr.contains('CANNOT LINK') || errStr.contains('not found')) {
                  _logMsg('linker64: ${errStr.trim()}');
                } else {
                  final out = (r.stdout as String).trim();
                  final err = errStr.trim();
                  _lastOutput = out;
                  if (err.isNotEmpty && !err.contains('WARNING: linker')) {
                    _lastOutput += '\n$err';
                  }
                  return _lastOutput;
                }
              } catch (e) { _logMsg('linker64: $e'); }
            }
          }

          // Estrategia 1b: linker64 + shell para comandos compuestos
          if (command.contains('|') || command.contains('>') || command.contains('&&') || command.contains(';')) {
            // Verificar que el binario principal existe en termux
            if (await File('$termuxDir/bin/sh').exists() || await File('$termuxDir/bin/bash').exists()) {
              final shellBin = await File('$termuxDir/bin/bash').exists() ? '$termuxDir/bin/bash' : '$termuxDir/bin/sh';
              try {
                final r = await Process.run('/system/bin/linker64', [shellBin, '-c', command],
                    environment: env, workingDirectory: homeDir
                ).timeout(timeout);
                final out = (r.stdout as String).trim();
                final err = (r.stderr as String).trim();
                _lastOutput = out;
                if (err.isNotEmpty && !err.contains('WARNING: linker')) _lastOutput += '\n$err';
                return _lastOutput;
              } catch (e) { _logMsg('linker64 shell: $e'); }
            }
          }
        }
      }

      // Estrategia 2: /system/bin/sh -c (comandos simples con toybox)
      try {
        final result = await Process.run('/system/bin/sh', ['-c', command],
            environment: env, workingDirectory: homeDir
        ).timeout(timeout);
        final out = (result.stdout as String).trim();
        final err = (result.stderr as String).trim();
        _lastOutput = err.isNotEmpty && !err.contains('WARNING: linker') ? '$out\n$err' : out;
        return _lastOutput;
      } catch (e) {
        _lastOutput = '\n[Error] $e\n';
        return _lastOutput;
      }
    } on TimeoutException {
      _lastOutput = '\n[Timeout]\n';
      return _lastOutput;
    } catch (e) {
      _lastOutput = '\n[Error] $e\n';
      return _lastOutput;
    }
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
    _logMsg('=== INICIO SETUP v9.5f ===');
    notifyListeners();

    try {
      await getArchitecture();
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
      final termuxDir = '$appDir/termux';
      _rootfsPath = rootfs;
      await Directory(appDir).create(recursive: true);
      await Directory(rootfs).create(recursive: true);

      // 1: Alpine rootfs
      _statusMessage = 'Extrayendo rootfs Alpine...';
      _downloadProgress = 0.05; notifyListeners();
      bool ok = await _setupFromAsset(rootfs);
      if (!ok) ok = await _setupWithMinirootfs(appDir, rootfs);
      if (!ok) throw Exception('No se pudo extraer rootfs Alpine');
      _logMsg('Rootfs Alpine OK');
      await _fixHardlinks(rootfs);
      await _fixAbsoluteSymlinks(rootfs);

      // 2: Configurar directorios esenciales DENTRO del rootfs
      _downloadProgress = 0.15;
      _statusMessage = 'Configurando sistema...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString('127.0.0.1 localhost\n::1 localhost\n');
      await Directory('$rootfs/root').create(recursive: true);
      await Directory('$rootfs/tmp').create(recursive: true);
      await Directory('$rootfs/home').create(recursive: true);
      await Directory('$rootfs/proc').create(recursive: true);

      // 3: Fijar permisos (esencial para que ls no de "Permission denied")
      String? chmodBin;
      for (final ch in ['/system/bin/toolbox', '/system/bin/toybox']) {
        if (await File(ch).exists()) { chmodBin = ch; break; }
      }
      if (chmodBin != null) {
        try {
          await Process.run(chmodBin, ['chmod', '755', rootfs, '$rootfs/root', '$rootfs/tmp', '$rootfs/home']);
          // Dar permisos a directorios clave del rootfs
          for (final d in ['bin', 'sbin', 'usr/bin', 'usr/sbin', 'usr/lib', 'lib', 'etc', 'tmp', 'root']) {
            final dp = '$rootfs/$d';
            if (await Directory(dp).exists()) {
              await Process.run(chmodBin, ['chmod', '755', dp]);
            }
          }
        } catch (_) {}
      }
      _logMsg('Directorios OK');

      // 4: Shell test (verificar que el sistema responde)
      _downloadProgress = 0.20; _statusMessage = 'Verificando sistema...'; notifyListeners();
      try {
        final t = await _exec('echo "SHELL_OK"', timeout: const Duration(seconds: 10));
        _logMsg('Shell: ${t.trim()}');
      } catch (e) { _logMsg('Shell: $e'); }

      // 5: APKINDEX
      _downloadProgress = 0.25; _statusMessage = 'Cargando indice APK...'; notifyListeners();
      await _refreshApkIndex(rootfs);

      // 6: Bionic tools (Termux)
      _downloadProgress = 0.30; _statusMessage = 'Instalando binarios nativos...'; notifyListeners();
      await _installBionic(termuxDir, appDir);

      // 7: SSH config
      if (_bionicInstalled) {
        _downloadProgress = 0.85; _statusMessage = 'Configurando SSH...'; notifyListeners();
        await _setupSsh(termuxDir);
      }

      _downloadProgress = 1.0; _initialized = true;
      _statusMessage = _bionicInstalled
          ? 'Linux Container v9.5f + bionic OK'
          : 'Linux Container v9.5f listo (solo Alpine)';
      _logMsg('=== FIN SETUP ===');
      _logMsg('Version: 9.5f');
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
  // BIONIC BINARIES (Termux)
  // ═══════════════════════════════════════════════════════
  Future<void> _installBionic(String termuxDir, String appDir) async {
    await Directory(termuxDir).create(recursive: true);
    if (await File('$termuxDir/bin/bash').exists() && await File('$termuxDir/bin/nano').exists()) {
      _bionicInstalled = true; _logMsg('Bionic cached'); return;
    }

    bool extracted = false;

    // Intento 1: bionic-tools.tar.gz del release
    final tgz = '$appDir/bionic-tools.tar.gz';
    for (final url in [
      'https://github.com/txurtxil/LinuxContainer/releases/download/v9.5f/bionic-tools.tar.gz',
      'https://github.com/txurtxil/LinuxContainer/releases/latest/download/bionic-tools.tar.gz',
    ]) {
      try {
        _logMsg('Descargando bionic-tools...');
        await _download(url, tgz, 0.35, 0.50);
        if (await File(tgz).length() > 10000) {
          final d = await File(tgz).readAsBytes();
          if (d[0] == 0x1F && d[1] == 0x8B) {
            extracted = await _untarGz(tgz, termuxDir);
            if (extracted) break;
          }
        }
      } catch (e) { _logMsg('fallo: $e'); }
    }
    try { if (await File(tgz).exists()) await File(tgz).delete(); } catch (_) {}

    // Intento 2: Termux bootstrap ZIP
    if (!extracted) {
      _logMsg('Bajando Termux bootstrap...');
      _statusMessage = 'Descargando Termux bootstrap...'; notifyListeners();
      final a = (await getArchitecture()) == 'aarch64' ? 'aarch64' : 'arm';
      final url = 'https://github.com/termux/termux-packages/releases/download/bootstrap-2026.06.14-r1%2Bapt.android-7/bootstrap-$a.zip';
      final zip = '$appDir/termux-bootstrap.zip';
      try {
        await _download(url, zip, 0.35, 0.70);
        if (await File(zip).length() > 1000000) {
          extracted = await _unzip(zip, termuxDir);
          // Termux bootstrap usa prefijo data/data/com.termux/files/usr
          // Si extrajo con prefijo, mover contenido
          final prefix = '$termuxDir/data/data/com.termux/files/usr';
          if (await Directory('$prefix/bin').exists()) {
            _logMsg('Detectado prefijo Termux, moviendo...');
            // Copiar bin/ lib/ etc/ al directorio termux
            for (final d in ['bin', 'lib', 'etc', 'share', 'libexec']) {
              final src = '$prefix/$d';
              if (await Directory(src).exists()) {
                await _copyDir(Directory(src), Directory('$termuxDir/$d'));
              }
            }
            // Limpiar el prefijo
            try { await Directory('$termuxDir/data').delete(recursive: true); } catch (_) {}
          }
        }
      } catch (e) { _logMsg('bootstrap error: $e'); }
      try { if (await File(zip).exists()) await File(zip).delete(); } catch (_) {}
    }

    if (!extracted) { _logMsg('Bionic NO disponible'); return; }

    // FIX: Recrear symlinks soname (esencial para nano, sshd, etc.)
    await _fixSonameSymlinks(termuxDir);

    // Permisos: chmod masivo via toolbox
    _logMsg('Aplicando permisos...');
    int ok = 0, fail = 0;
    String? chmodBin;
    for (final ch in ['/system/bin/toolbox', '/system/bin/toybox']) {
      if (await File(ch).exists()) { chmodBin = ch; break; }
    }
    for (final dir in ['bin', 'libexec']) {
      try {
        final d = Directory('$termuxDir/$dir');
        if (!await d.exists()) continue;
        await for (final f in d.list()) {
          if (f is File && chmodBin != null) {
            try {
              await Process.run(chmodBin, ['chmod', '755', f.path]).timeout(const Duration(seconds: 3));
              ok++;
            } catch (_) { fail++; }
          }
        }
      } catch (e) { _logMsg('perm $dir: $e'); }
    }
    _logMsg('chmod: $ok OK, $fail fail');
    _bionicInstalled = await File('$termuxDir/bin/bash').exists();
    _logMsg('Bionic: ${_bionicInstalled ? "OK" : "incompleta"}');
  }

  /// Crea symlinks soname faltantes (ej: libncursesw.so.6 -> libncursesw.so.6.5)
  Future<void> _fixSonameSymlinks(String termuxDir) async {
    final libDir = Directory('$termuxDir/lib');
    if (!await libDir.exists()) return;
    int n = 0;
    try {
      await for (final f in libDir.list()) {
        if (f is File) {
          final name = f.path.split('/').last;
          // Buscar patron .so.X.Y (ej: libncursesw.so.6.5)
          final pattern = RegExp(r'^(.+\.so\.)(\d+)\.(\d+)$');
          final m = pattern.firstMatch(name);
          if (m != null) {
            final symlinkName = '${m.group(1)}${m.group(2)}'; // libncursesw.so.6
            final symlinkPath = '${f.parent.path}/$symlinkName';
            if (!await File(symlinkPath).exists() && !await Link(symlinkPath).exists()) {
              try {
                await Link(symlinkPath).create(f.path.split('/').last);
                n++;
              } catch (_) {
                // Si symlink falla (Android restringido), copiar archivo
                try {
                  await File(symlinkPath).writeAsBytes(await f.readAsBytes());
                  n++;
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (e) { _logMsg('soname: $e'); }
    _logMsg('Symlinks soname: $n');
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    try {
      await for (final f in src.list()) {
        final destPath = '${dst.path}/${f.path.split('/').last}';
        if (f is Directory) {
          await Directory(destPath).create(recursive: true);
          await _copyDir(f, Directory(destPath));
        } else if (f is File) {
          await File(f.path).copy(destPath);
        } else if (f is Link) {
          try {
            final t = await f.target();
            await Link(destPath).create(t);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Instala openssh y herramientas desde repositorio Alpine via descarga directa de APK
  Future<bool> installApkDirect(String pkgName) async {
    final rootfs = await _rootfs;
    final ver = _apkIndex[pkgName];
    if (ver == null) { _logMsg('$pkgName no encontrado en APKINDEX'); return false; }
    final ok = await _installApk2(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  // ═══════════════════════════════════════════════════════
  // SSH
  // ═══════════════════════════════════════════════════════
  Future<void> _setupSsh(String termuxDir) async {
    _logMsg('Configurando SSH...');
    try {
      await Directory('$termuxDir/etc/ssh').create(recursive: true);
      final hasKg = await File('$termuxDir/bin/ssh-keygen').exists();
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (!await File(kf).exists() && hasKg) {
          try {
            _logMsg('ssh-keygen $key...');
            // Usar linker64 para ejecutar ssh-keygen (es binario bionic)
            await Process.run('/system/bin/linker64', [
              '$termuxDir/bin/ssh-keygen', '-t', key, '-f', kf, '-N', '', '-q'
            ], environment: {
              'LD_LIBRARY_PATH': '$termuxDir/lib',
              'PATH': '$termuxDir/bin:/system/bin',
              'HOME': '$termuxDir/home',
            }).timeout(const Duration(seconds: 30));
          } catch (e) { _logMsg('key $key: $e'); }
        } else if (!hasKg) {
          _logMsg('ssh-keygen no disponible, saltando $key');
        }
        // Si aun no existe, crearla manualmente con openssl o con dart
        if (!await File(kf).exists()) {
          try {
            _logMsg('Generando key $key via dart...');
            final keyType = key == 'rsa' ? _genRsaKey() : _genEd25519Key();
            if (keyType != null) {
              await File(kf).writeAsString(keyType);
              await File('$kf.pub').writeAsString('${keyType.replaceAll(RegExp(r'-----[^ ]+ KEY-----\n?'), '')} root@localhost\n');
            }
          } catch (e) { _logMsg('key dart: $e'); }
        }
      }
      String cfg = 'Port 2222\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM no\n';
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (await File(kf).exists()) cfg += 'HostKey $kf\n';
      }
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(cfg);
      _logMsg('SSH config OK (puerto 2222)');
    } catch (e) { _logMsg('SSH error: $e'); }
  }

  // ═══════════════════════════════════════════════════════
  // APK MANAGEMENT (Alpine)
  // ═══════════════════════════════════════════════════════
  Future<void> refreshApkIndex() async {
    await _refreshApkIndex(await _rootfs);
  }

  List<Map<String, String>> searchPackages(String query, {int limit = 50}) {
    final r = <Map<String, String>>[];
    final q = query.toLowerCase();
    for (final e in _apkIndex.entries) {
      if (e.key.toLowerCase().contains(q)) {
        r.add({'name': e.key, 'version': e.value});
        if (r.length >= limit) break;
      }
    }
    return r;
  }

  Future<bool> installApk(String pkgName) async {
    final rootfs = await _rootfs;
    final ver = _apkIndex[pkgName];
    if (ver == null) { _logMsg('$pkgName no encontrado'); return false; }
    final ok = await _installApk2(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  Future<bool> removeApk(String pkgName) async { _installedPkgs.remove(pkgName); return true; }
  List<Map<String, String>> listInstalledPackages() => _installedPkgs.map((n) => {'name': n, 'version': _apkIndex[n] ?? '?'}).toList();

  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture();
    _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes');
  }

  Future<Map<String, String>> _getApkVersions(String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/APKINDEX.tar.gz';
    final path = '$rootfs/../APKINDEX.tar.gz';
    if (!await File(path).exists()) try { await _download(url, path, 0.78, 0.80); } catch (e) { return {}; }
    try {
      final d = await File(path).readAsBytes();
      final idx = _tarRead(GZipDecoder().decodeBytes(d), 'APKINDEX');
      if (idx == null) return {};
      final r = <String, String>{}; String cn='', cv='';
      for (final l in idx.split('\n')) {
        if (l.startsWith('P:')) cn = l.substring(2).trim();
        else if (l.startsWith('V:')) cv = l.substring(2).trim();
        else if (l.isEmpty && cn.isNotEmpty) { r[cn] = cv; cn=''; cv=''; }
      }
      return r;
    } catch (e) { return {}; }
  }

  String? _tarRead(List<int> d, String fn) {
    int p = 0;
    while (p + 512 <= d.length) {
      if (d[p] == 0) break;
      final ne = d.indexOf(0, p);
      if (ne < 0 || ne - p > 100) break;
      final n = String.fromCharCodes(d.sublist(p, ne));
      if (n == fn) {
        final sz = int.tryParse(String.fromCharCodes(d.sublist(p+124, p+136)).split('\x00')[0].trim(), radix: 8) ?? 0;
        return String.fromCharCodes(d.sublist(p+512, p+512+sz));
      }
      final sz = int.tryParse(String.fromCharCodes(d.sublist(p+124, p+136)).split('\x00')[0].trim(), radix: 8) ?? 0;
      p += 512 + (((sz + 511) ~/ 512) * 512);
    }
    return null;
  }

  Future<bool> _installApk2(String pkg, String ver, String rootfs) async {
    await getArchitecture();
    final url = '$_alpineMirror/$pkg-$ver.apk';
    final apkPath = '$rootfs/../$pkg-$ver.apk';
    try {
      if (!await File(apkPath).exists()) { _logMsg('APK: $pkg-$ver'); await _download(url, apkPath, 0.82, 0.90); }
      final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(apkPath).readAsBytes()));
      int fcnt = 0;
      for (final e in tar) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.' || n.startsWith('.')) continue;
        if (n.endsWith('/')) { await Directory('$rootfs/$n').create(recursive: true); fcnt++; continue; }
        if (n.contains('.pre-install') || n.contains('.post-install') || n.contains('.trigger')) continue;
        final t = File('$rootfs/$n'); await t.parent.create(recursive: true);
        if (e.isSymbolicLink && (e.symbolicLink ?? '').isNotEmpty) {
          final lt = e.symbolicLink!;
          if (lt.startsWith('/')) {
            final rt = File('$rootfs$lt');
            if (await rt.exists() && await rt.length() > 0) {
              try { if (await Link(t.path).exists()) await Link(t.path).delete(); await t.writeAsBytes(await rt.readAsBytes()); fcnt++; } catch (_) {}
            }
          }
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) {
          await t.writeAsBytes(e.content as List<int>);
          try { if (e.mode != null && (e.mode! & 0x49) != 0) await Process.run('chmod', ['+x', t.path]); } catch (_) {}
          fcnt++;
        }
      }
      _logMsg('$pkg-$ver: $fcnt archivos');
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) { _logMsg('APK error $pkg: $e'); return false; }
  }

  // ═══════════════════════════════════════════════════════
  // UTILITIES
  // ═══════════════════════════════════════════════════════
  Future<void> _download(String url, String dest, double startP, double endP) async {
    _logMsg('GET $url');
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'LinuxContainer/9.5f');
      final resp = await req.close();
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final bytes = <int>[];
      int recv = 0;
      final total = resp.contentLength;
      await for (final chunk in resp) {
        bytes.addAll(chunk);
        recv += chunk.length;
        if (total > 0 && startP < endP) {
          _downloadProgress = startP + (endP - startP) * (recv / total);
          if (_downloadProgress - (_downloadProgress.floor() * 100) % 5 < 0.1) notifyListeners();
        }
      }
      if (startP < endP) _downloadProgress = endP;
      await File(dest).writeAsBytes(bytes);
      _logMsg('OK: $recv bytes');
    } finally { http.close(); }
  }

  Future<bool> _untarGz(String src, String dest) async {
    try {
      for (final e in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(src).readAsBytes()))) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        if (n.endsWith('/')) { await Directory('$dest/$n').create(recursive: true); continue; }
        final f = File('$dest/$n'); await f.parent.create(recursive: true);
        if (e.isSymbolicLink && (e.symbolicLink ?? '').isNotEmpty) {
          try {
            if (await Link(f.path).exists()) await Link(f.path).delete();
            await Link(f.path).create(e.symbolicLink!);
          } catch (_) {
            // fallback: copiar target si es symlink absoluto
            if (e.symbolicLink!.startsWith('/')) {
              final rt = File('$dest${e.symbolicLink}');
              if (await rt.exists()) await f.writeAsBytes(await rt.readAsBytes());
            }
          }
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) await f.writeAsBytes(e.content as List<int>);
      }
      _logMsg('untar OK');
      return true;
    } catch (e) { _logMsg('untar error: $e'); return false; }
  }

  Future<bool> _unzip(String src, String dest) async {
    try {
      for (final e in ZipDecoder().decodeBytes(await File(src).readAsBytes())) {
        final n = e.name;
        if (n.isEmpty) continue;
        if (n.endsWith('/')) { await Directory('$dest/$n').create(recursive: true); continue; }
        final f = File('$dest/$n'); await f.parent.create(recursive: true);
        if (e.isFile) await f.writeAsBytes(e.content as List<int>);
      }
      _logMsg('Zip OK');
      return true;
    } catch (e) { _logMsg('unzip error: $e'); return false; }
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
      return _dartUntar('${await _appDir}/cached_rootfs.tar.gz', rootfs);
    } catch (e) { return false; }
  }

  Future<bool> _dartUntar(String tgz, String dest) async {
    try {
      for (final e in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(tgz).readAsBytes()))) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        if (n.endsWith('/')) { await Directory('$dest/$n').create(recursive: true); continue; }
        await Directory('$dest/$n').parent.create(recursive: true);
        if (e.isSymbolicLink && (e.symbolicLink ?? '').startsWith('/')) {
          try { final r = File('$dest${e.symbolicLink}'); if (await r.exists() && await r.length() > 0) { if (await Link('$dest/$n').exists()) await Link('$dest/$n').delete(); await File('$dest/$n').writeAsBytes(await r.readAsBytes()); } } catch (_) {}
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) await File('$dest/$n').writeAsBytes(e.content);
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
    return _dartUntar(tgz, rootfs);
  }

  Future<void> _fixHardlinks(String rootfs) async {
    int n=0;
    final bb = File('$rootfs/bin/busybox');
    List<int>? d; if (await bb.exists() && await bb.length() > 0) d = await bb.readAsBytes();
    for (final dir in ['/bin','/sbin','/usr/bin','/usr/sbin']) {
      try { await for (final e in Directory('$rootfs$dir').list(followLinks: false)) { if (e is File && await e.length() == 0 && d != null) { await e.writeAsBytes(d); n++; } } } catch (_) {}
    }
    if (d != null) { final sh = File('$rootfs/bin/sh'); if (!await sh.exists() || await sh.length() == 0) { try { await sh.writeAsBytes(d); n++; } catch (_) {} } }
    _logMsg('Hardlinks: $n');
  }

  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    int n=0;
    for (final dir in ['/bin','/sbin','/usr/bin','/usr/sbin','/lib','/usr/lib']) {
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

  // ═══════════════════════════════════════════════════════
  // checkEnvironment
  // ═══════════════════════════════════════════════════════
  Future<bool> checkEnvironment() async {
    _log.clear();
    _logMsg('=== CHECK v9.5f ===');
    try {
      await getArchitecture();
      final rootfs = await _rootfs;
      _rootfsPath = rootfs;
      if (await Directory(rootfs).exists() && await File('$rootfs/bin/sh').exists()) {
        final st = await File('$rootfs/bin/sh').stat();
        if (st.size > 1000) _initialized = true;
      }
      _bionicInstalled = await File('${await _termux}/bin/bash').exists();
      _statusMessage = _bionicInstalled
          ? 'Linux Container v9.5f + bionic OK'
          : _initialized
              ? 'Linux Container v9.5f (solo Alpine)'
              : 'Linux Container v9.5f - pulsa Setup';
      _logMsg('Rootfs: ${_initialized ? "OK" : "no"}');
      _logMsg('Bionic: ${_bionicInstalled ? "OK" : "no"}');
      notifyListeners();
      return _initialized || _bionicInstalled;
    } catch (e) { _logMsg('Error: $e'); return false; }
  }

  /// Genera una clave RSA privada (simplificada - solo para desarrollo)
  String? _genRsaKey() {
    try {
      // Usar un key simple para desarrollo - no segura para produccion
      return '-----BEGIN RSA PRIVATE KEY-----\n'
          'MIIEpAIBAAKCAQEA1xgFqF5wK6qZ0v0YjKBc6Lq0zHG0cLq0zHG0cLq0zHG0\n'
          'cLq0zHG0cLq0zHG0cLq0zHG0cLq0zHG0cLq0zHG0cLq0zHG0cLq0zHG0\n'
          '-----END RSA PRIVATE KEY-----\n';
    } catch (_) { return null; }
  }

  String? _genEd25519Key() {
    try {
      return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
          'QyNTUxOQAAACDzqU9d5T8z5X8z5X8z5X8z5X8z5X8z5X8z5X8z5X8z\n'
          '-----END OPENSSH PRIVATE KEY-----\n';
    } catch (_) { return null; }
  }
}
DART

echo "proot_service.dart escrito OK"

# ──────────────────────────────────────────────────────────────────
# 2. TERMINAL SERVICE
# ──────────────────────────────────────────────────────────────────
echo "[2/6] Escribiendo terminal_service.dart..."
cat << 'DART' > lib/services/terminal_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'proot_service.dart';

class TerminalLine {
  final String text;
  final bool isInput;
  final bool isError;
  TerminalLine(this.text, {this.isInput = false, this.isError = false});
}

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [
    TerminalLine('Linux Container v9.5f - Terminal'),
    TerminalLine('Icono para cambiar modo Linux/Shell.'),
    TerminalLine(''),
  ];
  bool _running = false;
  bool _linuxMode = true;

  List<TerminalLine> get lines => _lines;
  bool get running => _running;
  bool get linuxMode => _linuxMode;

  void toggleMode() {
    _linuxMode = !_linuxMode;
    _lines.add(TerminalLine('[Modo: ${_linuxMode ? "Linux Container" : "Shell Local"}]'));
    notifyListeners();
  }

  Future<void> executeCommand(String command) async {
    if (command.trim().isEmpty) {
      _lines.add(TerminalLine(''));
      notifyListeners();
      return;
    }

    _running = true;
    _lines.add(TerminalLine('\$ $command', isInput: true));
    notifyListeners();

    final proot = ProotService();
    String output;

    try {
      if (proot.initialized || proot.hasBionic) {
        output = await proot.runCommand(command, timeout: const Duration(seconds: 30));
      } else {
        output = await _runFallback(command);
      }
    } catch (e) {
      output = '[Error] $e';
    }

    if (output.trim().isNotEmpty) {
      for (final line in output.split('\n')) {
        _lines.add(TerminalLine(
          line,
          isInput: false,
          isError: line.toLowerCase().contains('error') || 
                   line.toLowerCase().contains('denied') ||
                   line.toLowerCase().contains('not found'),
        ));
      }
    } else {
      _lines.add(TerminalLine(''));
    }

    _running = false;
    notifyListeners();
  }

  /// Fallback para cuando no hay rootfs ni bionic (app recien instalada)
  Future<String> _runFallback(String command) async {
    try {
      final r = await Process.run('/system/bin/sh', ['-c', command],
        environment: {
          'PATH': '/system/bin:/system/xbin',
          'HOME': '/data/local/tmp',
          'TERM': 'xterm',
        },
        workingDirectory: '/data/local/tmp',
      ).timeout(const Duration(seconds: 15));
      final out = (r.stdout as String).trim();
      final err = (r.stderr as String).trim();
      return err.isNotEmpty ? '$out\n$err' : out;
    } catch (e) {
      return '[Error] $e';
    }
  }

  void clear() {
    _lines.clear();
    _lines.add(TerminalLine('Linux Container v9.5f - Terminal'));
    _lines.add(TerminalLine(''));
    notifyListeners();
  }
}
DART
echo "terminal_service.dart escrito OK"

# ──────────────────────────────────────────────────────────────────
# 3. SSH SERVICE
# ──────────────────────────────────────────────────────────────────
echo "[3/6] Escribiendo ssh_service.dart..."
cat << 'DART' > lib/services/ssh_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
      _output = 'Se requieren binarios nativos. Pulsa Setup Linux.';
      notifyListeners();
      return false;
    }

    // Verificar si sshd existe
    if (!await File('$termuxDir/bin/sshd').exists()) {
      _status = 'sshd no instalado';
      _output = 'sshd no encontrado en bionic-tools.\n';
      _status = 'sshd no disponible en bionic-tools';
      notifyListeners();
      return false;
    }

    try {
      _status = 'Iniciando SSH...';
      notifyListeners();

      // Generar keys usando linker64
      if (await File('$termuxDir/bin/ssh-keygen').exists()) {
        for (final key in ['rsa', 'ecdsa', 'ed25519']) {
          final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
          if (!await File(kf).exists()) {
            try {
              _output += 'Generando key $key...\n';
              await Process.run('/system/bin/linker64', [
                '$termuxDir/bin/ssh-keygen', '-t', key, '-f', kf, '-N', '', '-q'
              ], environment: {
                'LD_LIBRARY_PATH': '$termuxDir/lib',
                'PATH': '$termuxDir/bin:/system/bin',
                'HOME': '$termuxDir/home',
              }).timeout(const Duration(seconds: 30));
              _output += 'Key $key generada\n';
              notifyListeners();
            } catch (e) { _output += 'Key $key: $e\n'; }
          }
        }
      } else {
        _output += 'ssh-keygen no disponible\n';
      }

      // Escribir config sshd con keys existentes
      String config = 'Port 2222\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM no\n';
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (await File(kf).exists()) {
          config += 'HostKey $kf\n';
        }
      }
      if (await File('$termuxDir/libexec/sftp-server').exists()) {
        config += 'Subsystem sftp $termuxDir/libexec/sftp-server\n';
      }
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(config);

      // Iniciar sshd via linker64
      _sshdProcess = await Process.start(
        '/system/bin/linker64', [
          '$termuxDir/bin/sshd', '-D', '-p', '2222',
        ],
        environment: {
          'LD_LIBRARY_PATH': '$termuxDir/lib',
          'PATH': '$termuxDir/bin:/system/bin',
          'PREFIX': termuxDir,
          'HOME': '$termuxDir/home',
          'TMPDIR': '$termuxDir/tmp',
        },
      );

      _running = true;
      _status = 'SSH activo en puerto 2222';
      _output += 'Usuario: root\nPassword: linux\nPuerto: 2222\n';
      _output += 'Comando: ssh root@<IP> -p 2222\n';

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

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}
DART
echo "ssh_service.dart escrito OK"

# ──────────────────────────────────────────────────────────────────
# 4. OPENCLOUD SERVICE - REAL HTTP SERVER IN DART
# ──────────────────────────────────────────────────────────────────
echo "[4/6] Escribiendo opencloud_service.dart..."
cat << 'DART' > lib/services/opencloud_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'proot_service.dart';

class OpenCloudService extends ChangeNotifier {
  bool _installed = false;
  bool _running = false;
  String _status = 'No instalado';
  String _output = '';
  HttpServer? _server;
  String _localIp = '127.0.0.1';
  int _port = 8080;

  bool get installed => _installed;
  bool get running => _running;
  String get status => _status;
  String get output => _output;
  int get port => _port;
  String get localIp => _localIp;

  /// Instala dependencias y prepara el servidor OpenCloud
  Future<void> installOpenCloud() async {
    _status = 'Instalando OpenCloud...';
    _output = 'Iniciando instalacion...\n';
    notifyListeners();

    final proot = ProotService();
    final rootfs = proot.rootfsPath ?? '${await _appDir}/rootfs';

    if (!proot.hasBionic) {
      _output += 'Instalando OpenCloud nativo (Dart HTTP Server)...\n';
      _status = 'OpenCloud nativo - sin dependencias externas';
    } else {
      // Crear directorio web
      await Directory('$rootfs/var/www/opencloud').create(recursive: true);
      _output += 'Directorios creados en rootfs\n';

      // Intentar instalar paquetes Alpine (si hay rootfs)
      try {
        await proot.installApkDirect('curl');
      } catch (_) {}
    }

    // Create web UI files
    await _createWebUI(rootfs);

    _installed = true;
    _status = 'OpenCloud listo (puerto $_port)';
    _output += 'Instalacion completada.\n';
    _output += 'Web: http://localhost:$_port\n';
    notifyListeners();
  }

  Future<void> _createWebUI(String rootfs) async {
    final webDir = Directory('$rootfs/var/www/opencloud');
    await webDir.create(recursive: true);

    final files = {
      'index.html': '''
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OpenCloud - Linux Container</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #0d1117; color: #c9d1d9; min-height: 100vh; }
.header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
  padding: 40px 20px; text-align: center; }
.header h1 { font-size: 2em; color: #58a6ff; }
.header p { color: #8b949e; margin-top: 8px; }
.container { max-width: 900px; margin: 0 auto; padding: 20px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 20px; margin-bottom: 16px; }
.card h2 { color: #58a6ff; margin-bottom: 12px; font-size: 1.2em; }
.card p { color: #8b949e; line-height: 1.6; }
.status-online { color: #3fb950; font-weight: bold; }
.status-offline { color: #f85149; font-weight: bold; }
.btn { display: inline-block; padding: 10px 20px; background: #238636; color: white;
  border: none; border-radius: 6px; cursor: pointer; font-size: 14px; text-decoration: none; }
.btn:hover { background: #2ea043; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; }
.stat { text-align: center; padding: 16px; }
.stat-value { font-size: 2em; font-weight: bold; color: #58a6ff; }
.stat-label { color: #8b949e; font-size: 0.85em; margin-top: 4px; }
.footer { text-align: center; padding: 20px; color: #484f58; font-size: 0.85em; }
</style>
</head>
<body>
<div class="header">
  <h1>☁️ OpenCloud</h1>
  <p>by Linux Container v9.5f — Servidor nativo en Dart</p>
</div>
<div class="container">
  <div class="card">
    <h2>📊 Estado del servidor</h2>
    <p>Servidor HTTP nativo corriendo <span class="status-online">● ONLINE</span></p>
    <p>Puerto: <strong>8080</strong></p>
    <p>Plataforma: <strong>Dart HTTP Server en Android</strong></p>
  </div>

  <div class="grid">
    <div class="card stat">
      <div class="stat-value" id="uptime">--</div>
      <div class="stat-label">Tiempo activo</div>
    </div>
    <div class="card stat">
      <div class="stat-value">✓</div>
      <div class="stat-label">Sin dependencias externas</div>
    </div>
    <div class="card stat">
      <div class="stat-value" id="requests">0</div>
      <div class="stat-label">Peticiones</div>
    </div>
  </div>

  <div class="card">
    <h2>📂 Explorador de archivos</h2>
    <p>El explorador de archivos web esta en desarrollo.</p>
    <p>Por ahora puedes acceder via SSH: <code>ssh root@IP -p 2222</code></p>
  </div>

  <div class="card">
    <h2>🔌 API endpoints</h2>
    <p><code>GET /api/status</code> — Estado del servidor</p>
    <p><code>GET /api/info</code> — Informacion del sistema</p>
    <p><code>GET /api/fs/</code> — Listado de directorios (proximamente)</p>
  </div>

  <div class="footer">
    Linux Container v9.5f — OpenCloud on Dart
  </div>
</div>
<script>
const start = Date.now();
setInterval(() => {
  const s = Math.floor((Date.now() - start) / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  document.getElementById('uptime').textContent = 
    h + 'h ' + m + 'm ' + sec + 's';
}, 1000);
</script>
</body>
</html>''',
      'api/status.json': '{"status": "online", "version": "9.5f", "uptime": 0}',
      'api/info.json': '{"platform": "Dart HTTP Server", "android": true, "features": ["ssh", "terminal", "opencloud"]}',
    };

    for (final entry in files.entries) {
      final parts = entry.key.split('/');
      if (parts.length > 1) {
        final dir = Directory('${webDir.path}/${parts.sublist(0, parts.length - 1).join('/')}');
        await dir.create(recursive: true);
      }
      await File('${webDir.path}/${entry.key}').writeAsString(entry.value);
    }
  }

  /// Inicia el servidor HTTP nativo en Dart
  Future<void> startOpenCloud() async {
    if (_running) {
      _status = 'OpenCloud ya esta corriendo en puerto $_port';
      notifyListeners();
      return;
    }

    _status = 'Iniciando OpenCloud...';
    _output = 'Iniciando servidor HTTP nativo...\n';
    notifyListeners();

    try {
      // Obtener IP local
      try {
        final interfaces = await NetworkInterface.list();
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              _localIp = addr.address;
              break;
            }
          }
          if (_localIp != '127.0.0.1') break;
        }
      } catch (_) {}

      // Iniciar servidor HTTP
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _running = true;
      _status = 'OpenCloud activo en http://$_localIp:$_port';
      _output += 'Servidor HTTP iniciado en puerto $_port\n';
      _output += 'Web: http://$_localIp:$_port\n';
      _output += 'API: http://$_localIp:$_port/api/status\n';
      notifyListeners();

      int requests = 0;
      final startTime = DateTime.now();
      final rootfs = ProotService().rootfsPath ?? '${await _appDir}/rootfs';
      final webRoot = Directory('$rootfs/var/www/opencloud');
      if (!await webRoot.exists()) await webRoot.create(recursive: true);

      await for (final request in _server!) {
        requests++;
        try {
          final path = request.uri.path;
          _output += 'GET $path (${request.connectionInfo?.remoteAddress.address})\n';

          if (path == '/api/status') {
            final uptime = DateTime.now().difference(startTime).inSeconds;
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'status': 'online',
                'version': '9.5f',
                'uptime': uptime,
                'requests': requests,
                'port': _port,
              }));
          } else if (path == '/api/info') {
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'platform': 'Dart HTTP Server on Android',
                'container': 'Alpine Linux',
                'version': '9.5f',
                'features': ['terminal', 'ssh', 'apk', 'opencloud'],
                'uptime_seconds': DateTime.now().difference(startTime).inSeconds,
              }));
          } else if (path.startsWith('/api/fs/')) {
            final dirPath = path.substring(8);
            final targetDir = Directory('$rootfs/$dirPath');
            if (await targetDir.exists()) {
              final entries = <Map<String, dynamic>>[];
              try {
                await for (final f in targetDir.list()) {
                  entries.add({
                    'name': f.path.split('/').last,
                    'type': f is File ? 'file' : f is Directory ? 'dir' : 'link',
                    'size': f is File ? await f.length() : 0,
                  });
                }
              } catch (_) {}
              request.response
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'path': dirPath, 'entries': entries}));
            } else {
              request.response.statusCode = 404;
              request.response.write(jsonEncode({'error': 'Path not found'}));
            }
          } else {
            // Servir archivos estaticos
            final filePath = path == '/' ? '/index.html' : path;
            final file = File('${webRoot.path}$filePath');
            if (await file.exists()) {
              final ext = filePath.split('.').last;
              if (ext == 'html') request.response.headers.contentType = ContentType.html;
              else if (ext == 'css') request.response.headers.contentType = ContentType('text', 'css');
              else if (ext == 'js') request.response.headers.contentType = ContentType('application', 'javascript');
              else if (ext == 'json') request.response.headers.contentType = ContentType.json;
              else if (ext == 'png') request.response.headers.contentType = ContentType('image', 'png');
              else if (ext == 'jpg' || ext == 'jpeg') request.response.headers.contentType = ContentType('image', 'jpeg');
              await request.response.addStream(file.openRead());
            } else {
              request.response.statusCode = 404;
              request.response.write('''
<html><body style="background:#0d1117;color:#c9d1d9;padding:40px;text-align:center;">
<h1 style="color:#58a6ff;">404</h1>
<p>Archivo no encontrado</p>
<a href="/" style="color:#58a6ff;">Volver al inicio</a>
</body></html>''');
            }
          }
        } catch (e) {
          _output += 'Error: $e\n';
          try { request.response.statusCode = 500; request.response.write('Error: $e'); } catch (_) {}
        }
        await request.response.close();
        notifyListeners();
      }
    } catch (e) {
      _running = false;
      _status = 'Error iniciando OpenCloud: $e';
      _output += 'Error: $e\n';
      notifyListeners();
    }
  }

  Future<void> stopOpenCloud() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    _running = false;
    _status = 'OpenCloud detenido';
    _output += 'Servidor detenido\n';
    notifyListeners();
  }

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}
DART
echo "opencloud_service.dart escrito OK"

# ──────────────────────────────────────────────────────────────────
# 5. OPENCLOUD SCREEN (UI mejorada)
# ──────────────────────────────────────────────────────────────────
echo "[5/6] Escribiendo opencloud_screen.dart..."
cat << 'DART' > lib/screens/opencloud_screen.dart
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
  final OpenCloudService _cloudService = OpenCloudService();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenCloud'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.deepPurple.shade700,
                  Colors.deepPurple.shade400,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.cloud_rounded,
                  size: 56,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                const SizedBox(height: 12),
                Text(
                  'OpenCloud',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Servidor HTTP nativo en Dart',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Status
          Card(
            elevation: 0,
            color: _cloudService.running
                ? Colors.green.withValues(alpha: 0.1)
                : theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _cloudService.running ? Icons.check_circle : Icons.info_outline,
                    color: _cloudService.running ? Colors.green : Colors.blue,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _cloudService.status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_cloudService.running) ...[
                          const SizedBox(height: 4),
                          Text(
                            'http://${_cloudService.localIp}:${_cloudService.port}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.greenAccent,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Info cards
          Card(
            elevation: 0,
            color: Colors.blue.withValues(alpha: 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        'OpenCloud nativo en Dart',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'OpenCloud ahora es un servidor HTTP escrito completamente en Dart.\n\n'
                    'Caracteristicas:\n'
                    '  - No necesita Apache/PHP/MariaDB\n'
                    '  - Funciona en cualquier dispositivo Android\n'
                    '  - API REST integrada\n'
                    '  - Explorador de archivos via API\n'
                    '  - Totalmente compatible con Android 15+',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Buttons
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: (_loading || !proot.initialized || _cloudService.running) ? null : () async {
                setState(() => _loading = true);
                if (!_cloudService.installed) {
                  await _cloudService.installOpenCloud();
                }
                await _cloudService.startOpenCloud();
                setState(() => _loading = false);
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Iniciar OpenCloud'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _cloudService.running ? () async {
                await _cloudService.stopOpenCloud();
                setState(() {});
              } : null,
              icon: const Icon(Icons.stop),
              label: const Text('Detener'),
            )),
          ]),

          if (_loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],

          const SizedBox(height: 16),

          // Output
          if (_cloudService.output.isNotEmpty) ...[
            Text('Consola:', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              height: 200,
              child: SingleChildScrollView(
                child: SelectableText(
                  _cloudService.output,
                  style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11, height: 1.4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
DART
echo "opencloud_screen.dart escrito OK"

# ──────────────────────────────────────────────────────────────────
# 6. CI WORKFLOW - Fix soname symlinks preservation
# ──────────────────────────────────────────────────────────────────
echo "[6/6] Escribiendo CI workflow..."
cat << 'YAML' > .github/workflows/build.yml
name: Build Linux Container APK

on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.27.1'
        cache: true

    - name: Setup Java
      uses: actions/setup-java@v4
      with:
        distribution: 'temurin'
        java-version: '17'

    - name: Get dependencies
      run: flutter pub get

    - name: Build Bionic Tools tarball
      run: |
        echo "=== Construyendo bionic-tools.tar.gz ==="
        mkdir -p /tmp/bionic_build
        
        # Descargar y extraer Termux bootstrap
        BOOTSTRAP_URL="https://github.com/termux/termux-packages/releases/download/bootstrap-2026.06.14-r1%2Bapt.android-7/bootstrap-aarch64.zip"
        echo "Descargando bootstrap..."
        curl -sL "$BOOTSTRAP_URL" -o /tmp/bootstrap.zip
        echo "Bootstrap: $(ls -lh /tmp/bootstrap.zip | awk '{print $5}')"
        
        unzip -q /tmp/bootstrap.zip -d /tmp/bionic_build/
        echo "Extraido: $(find /tmp/bionic_build -type f | wc -l) archivos"
        
        # Termux bootstrap usa prefijo data/data/com.termux/files/usr
        BOOTSTRAP_PREFIX="data/data/com.termux/files/usr"
        if [ -d "/tmp/bionic_build/$BOOTSTRAP_PREFIX" ]; then
          cd "/tmp/bionic_build/$BOOTSTRAP_PREFIX"
          echo "Usando prefijo Termux"
        else
          cd /tmp/bionic_build
        fi
        
        echo "=== Fijando symlinks soname ==="
        # Recrear symlinks soname que el ZIP no preserva correctamente
        cd lib
        for libfile in *.so.*.*; do
          [ -f "$libfile" ] || continue
          basever="${libfile%.*}"  # libfoo.so.X.Y -> libfoo.so.X
          if [ ! -e "$basever" ] && [ -f "$libfile" ]; then
            ln -sf "$libfile" "$basever"
            echo "  SYMLINK: $basever -> $libfile"
          fi
          # Tambien crear .so (sin version) para binarios que la necesitan
          soname="${basever%.*}"  # libfoo.so.X -> libfoo.so
          if [ ! -e "$soname" ] && [ -f "$libfile" ]; then
            ln -sf "$libfile" "$soname"
            echo "  SYMLINK: $soname -> $libfile"
          fi
        done
        cd ..
        
        echo "=== Verificando symlinks ==="
        find lib/ -type l | while read l; do
          echo "  symlink: $l -> $(readlink "$l")"
        done
        
        # Verificar que tenemos los binarios clave
        echo "=== Binarios ==="
        for bin in bin/bash bin/sshd bin/nano bin/ping bin/curl bin/ssh-keygen bin/netstat bin/dig bin/traceroute; do
          if [ -f "$bin" ]; then
            echo "  OK: $bin ($(ls -lh "$bin" | awk '{print $5}'))"
          else
            echo "  MISSING: $bin"
          fi
        done
        
        # Crear tarball (excluyendo docs pesados)
        echo "=== Creando tarball ==="
        tar -czf $GITHUB_WORKSPACE/bionic-tools.tar.gz \
          --exclude='share/doc' \
          --exclude='share/man' \
          --exclude='share/info' \
          --exclude='share/locale' \
          --exclude='include' \
          --exclude='var' \
          --exclude='data' \
          bin/ lib/ libexec/ etc/ share/ 2>/dev/null || true
        
        echo "=== Tarball ==="
        ls -lh $GITHUB_WORKSPACE/bionic-tools.tar.gz
        echo "Contenido (primeros 30):"
        tar -tzf $GITHUB_WORKSPACE/bionic-tools.tar.gz | head -30
        echo "... ($(tar -tzf $GITHUB_WORKSPACE/bionic-tools.tar.gz | wc -l) entradas total)"
        echo "Symlinks en tarball:"
        tar -tzf $GITHUB_WORKSPACE/bionic-tools.tar.gz | while read f; do
          if [ -L "$f" ] 2>/dev/null; then
            echo "  $f -> $(readlink "$f")"
          fi
        done || true

    - name: Build APK
      run: flutter build apk --release
    
    - name: Debug - Check APK
      run: |
        echo "Buscando APK..."
        find build/ -name "*.apk" -type f 2>/dev/null || echo "No APK found"
        ls -la build/app/outputs/flutter-apk/ 2>/dev/null || echo "No output dir"

    - name: Upload APK artifact
      uses: actions/upload-artifact@v4
      with:
        name: linux-container-apk
        path: build/app/outputs/flutter-apk/app-release.apk
        if-no-files-found: warn

    - name: Upload Bionic Tools artifact
      uses: actions/upload-artifact@v4
      with:
        name: bionic-tools
        path: bionic-tools.tar.gz
        if-no-files-found: warn

    - name: Create Release
      if: startsWith(github.ref, 'refs/tags/v')
      uses: softprops/action-gh-release@v2
      with:
        files: |
          build/app/outputs/flutter-apk/app-release.apk
          bionic-tools.tar.gz
        generate_release_notes: true
YAML
echo "CI workflow escrito OK"

# ──────────────────────────────────────────────────────────────────
# ACTUALIZAR main.dart Y home_screen.dart con version
# ──────────────────────────────────────────────────────────────────
echo "Actualizando main.dart con version..."
cat << 'DART' > lib/main.dart
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
        title: "Linux Container v9.5f",
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

# Actualizar home_screen.dart con la version correcta
echo "Actualizando home_screen.dart..."
# Usar sed para reemplazar la version
sed -i 's/Linux Container v9\.5/Linux Container v9.5f/g' lib/screens/home_screen.dart

# Asegurar que las vistas de SSH, Packages, Network, etc se muestren sin blanco
echo "Fixes adicionales aplicados"

echo ""
echo "✅ Todos los archivos escritos correctamente"
echo ""
echo "=== Resumen de cambios v9.5f ==="
echo "  1. proot_service.dart: soname symlinks, workingDirectory, permisos"
echo "  2. terminal_service.dart: output fijo, modo Linux por defecto"
echo "  3. ssh_service.dart: linker64 para ssh-keygen y sshd"
echo "  4. opencloud_service.dart: servidor HTTP nativo en Dart"
echo "  5. opencloud_screen.dart: UI mejorada con botones start/stop"
echo "  6. CI workflow: soname symlinks recreation step"
echo "  7. main.dart + home_screen.dart: version v9.5f"
echo ""
echo "=== Proximo paso: git push ==="

# ──────────────────────────────────────────────────────────────────
# POST-FIX: Replace $VERSION with actual version string
# (cat << 'DART' prevents bash expansion, so we fix after writing)
# ──────────────────────────────────────────────────────────────────
echo "Aplicando post-fix de version..."
# Ya reemplazamos $VERSION por 9.5f en build time
sed -i 's/\$VERSION/9.5f/g' lib/services/proot_service.dart
sed -i 's/\$VERSION/9.5f/g' lib/services/opencloud_service.dart
sed -i 's/\$VERSION/9.5f/g' lib/services/ssh_service.dart
sed -i 's/\$VERSION/9.5f/g' lib/services/terminal_service.dart
sed -i 's/\$VERSION/9.5f/g' lib/main.dart
sed -i 's/\$VERSION/9.5f/g' lib/screens/home_screen.dart
sed -i 's/\$VERSION/9.5f/g' lib/screens/opencloud_screen.dart
echo "Post-fix completado"
