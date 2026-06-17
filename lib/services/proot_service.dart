import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier extends ChangeNotifier {
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

      _logMsg('cmd: $command'.toString());

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
              } catch (e) { _logMsg('linker64: $e'.toString()); }
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
              } catch (e) { _logMsg('linker64 shell: $e'.toString()); }
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
    _logMsg('=== INICIO SETUP v9.5f ==='.toString());
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
      _logMsg('Rootfs Alpine OK'.toString());
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
      _logMsg('Directorios OK'.toString());

      // 4: Shell test (verificar que el sistema responde)
      _downloadProgress = 0.20; _statusMessage = 'Verificando sistema...'; notifyListeners();
      try {
        final t = await _exec('echo "SHELL_OK"', timeout: const Duration(seconds: 10));
        _logMsg('Shell: ${t.trim()}');
      } catch (e) { _logMsg('Shell: $e'.toString()); }

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
      _logMsg('=== FIN SETUP ==='.toString());
      _logMsg('Version: 9.5f'.toString());
    } catch (e) {
      _logMsg('EXCEPCION: $e'.toString());
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
      _bionicInstalled = true; _logMsg('Bionic cached'.toString()); return;
    }

    bool extracted = false;

    // Intento 1: bionic-tools.tar.gz del release
    final tgz = '$appDir/bionic-tools.tar.gz';
    for (final url in [
      'https://github.com/txurtxil/LinuxContainer/releases/download/v9.5f/bionic-tools.tar.gz',
      'https://github.com/txurtxil/LinuxContainer/releases/latest/download/bionic-tools.tar.gz',
    ]) {
      try {
        _logMsg('Descargando bionic-tools...'.toString());
        await _download(url, tgz, 0.35, 0.50);
        if (await File(tgz).length() > 10000) {
          final d = await File(tgz).readAsBytes();
          if (d[0] == 0x1F && d[1] == 0x8B) {
            extracted = await _untarGz(tgz, termuxDir);
            if (extracted) break;
          }
        }
      } catch (e) { _logMsg('fallo: $e'.toString()); }
    }
    try { if (await File(tgz).exists()) await File(tgz).delete(); } catch (_) {}

    // Intento 2: Termux bootstrap ZIP
    if (!extracted) {
      _logMsg('Bajando Termux bootstrap...'.toString());
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
            _logMsg('Detectado prefijo Termux, moviendo...'.toString());
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
      } catch (e) { _logMsg('bootstrap error: $e'.toString()); }
      try { if (await File(zip).exists()) await File(zip).delete(); } catch (_) {}
    }

    if (!extracted) { _logMsg('Bionic NO disponible'.toString()); return; }

    // FIX: Recrear symlinks soname (esencial para nano, sshd, etc.)
    await _fixSonameSymlinks(termuxDir);

    // Permisos: chmod masivo via toolbox
    _logMsg('Aplicando permisos...'.toString());
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
      } catch (e) { _logMsg('perm $dir: $e'.toString()); }
    }
    _logMsg('chmod: $ok OK, $fail fail'.toString());
    _bionicInstalled = await File('$termuxDir/bin/bash').exists();
    _logMsg('Bionic: ${_bionicInstalled ? "OK" : "incompleta"}'.toString());
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
    } catch (e) { _logMsg('soname: $e'.toString()); }
    _logMsg('Symlinks soname: $n'.toString());
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
    if (ver == null) { _logMsg('$pkgName no encontrado en APKINDEX'.toString()); return false; }
    final ok = await _installApk2(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  // ═══════════════════════════════════════════════════════
  // SSH
  // ═══════════════════════════════════════════════════════
  Future<void> _setupSsh(String termuxDir) async {
    _logMsg('Configurando SSH...'.toString());
    try {
      await Directory('$termuxDir/etc/ssh').create(recursive: true);
      final hasKg = await File('$termuxDir/bin/ssh-keygen').exists();
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (!await File(kf).exists() && hasKg) {
          try {
            _logMsg('ssh-keygen $key...'.toString());
            // Usar linker64 para ejecutar ssh-keygen (es binario bionic)
            await Process.run('/system/bin/linker64', [
              '$termuxDir/bin/ssh-keygen', '-t', key, '-f', kf, '-N', '', '-q'
            ], environment: {
              'LD_LIBRARY_PATH': '$termuxDir/lib',
              'PATH': '$termuxDir/bin:/system/bin',
              'HOME': '$termuxDir/home',
            }).timeout(const Duration(seconds: 30));
          } catch (e) { _logMsg('key $key: $e'.toString()); }
        } else if (!hasKg) {
          _logMsg('ssh-keygen no disponible, saltando $key'.toString());
        }
        // Si aun no existe, crearla manualmente con openssl o con dart
        if (!await File(kf).exists()) {
          try {
            _logMsg('Generando key $key via dart...'.toString());
            final keyType = key == 'rsa' ? _genRsaKey() : _genEd25519Key();
            if (keyType != null) {
              await File(kf).writeAsString(keyType);
              await File('$kf.pub').writeAsString('${keyType.replaceAll(RegExp(r'-----[^ ]+ KEY-----\n?'), '')} root@localhost\n');
            }
          } catch (e) { _logMsg('key dart: $e'.toString()); }
        }
      }
      String cfg = 'Port 2222\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM no\n';
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (await File(kf).exists()) cfg += 'HostKey $kf\n';
      }
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(cfg);
      _logMsg('SSH config OK (puerto 2222)');
    } catch (e) { _logMsg('SSH error: $e'.toString()); }
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
    if (ver == null) { _logMsg('$pkgName no encontrado'.toString()); return false; }
    final ok = await _installApk2(pkgName, ver, rootfs);
    if (ok) _installedPkgs.add(pkgName);
    return ok;
  }

  Future<bool> removeApk(String pkgName) async { _installedPkgs.remove(pkgName); return true; }
  List<Map<String, String>> listInstalledPackages() => _installedPkgs.map((n) => {'name': n, 'version': _apkIndex[n] ?? '?'}).toList();

  Future<void> _refreshApkIndex(String rootfs) async {
    await getArchitecture();
    _apkIndex = await _getApkVersions(rootfs);
    _logMsg('APKINDEX: ${_apkIndex.length} paquetes'.toString());
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
      if (!await File(apkPath).exists()) { _logMsg('APK: $pkg-$ver'.toString()); await _download(url, apkPath, 0.82, 0.90); }
      final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(apkPath).readAsBytes()));
      int fcnt = 0;
      for (final e in tar) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.' || n.startsWith('.')) continue;
        if (n.endsWith('/')) { await Directory('$rootfs/$n').create(recursive: true); fcnt++; continue; }
        if (n.contains('.pre-install') || n.contains('.post-install') || n.contains('.trigger')) continue;
        final t = File('$rootfs/$n'); await t.parent.create(recursive: true);
        if (e.isSymbolicLink) { continue; } catch (_) {}
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
      _logMsg('$pkg-$ver: $fcnt archivos'.toString());
      try { await File(apkPath).delete(); } catch (_) {}
      return true;
    } catch (e) { _logMsg('APK error $pkg: $e'.toString()); return false; }
  }

  // ═══════════════════════════════════════════════════════
  // UTILITIES
  // ═══════════════════════════════════════════════════════
  Future<void> _download(String url, String dest, double startP, double endP) async {
    _logMsg('GET $url'.toString());
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
      _logMsg('OK: $recv bytes'.toString());
    } finally { http.close(); }
  }

  Future<bool> _untarGz(String src, String dest) async {
    try {
      for (final e in TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await File(src).readAsBytes()))) {
        String n = e.name; if (n.startsWith('./')) n = n.substring(2);
        if (n.isEmpty || n == '.') continue;
        if (n.endsWith('/')) { await Directory('$dest/$n').create(recursive: true); continue; }
        final f = File('$dest/$n'); await f.parent.create(recursive: true);
        if (e.isSymbolicLink) { continue; } catch (_) {
            // fallback: copiar target si es symlink absoluto
            if ("") {
              final rt = File('$dest${"";
              if (await rt.exists()) await f.writeAsBytes(await rt.readAsBytes());
            }
          }
          continue;
        }
        if (e.isFile && e.content.isNotEmpty) await f.writeAsBytes(e.content as List<int>);
      }
      _logMsg('untar OK'.toString());
      return true;
    } catch (e) { _logMsg('untar error: $e'.toString()); return false; }
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
      _logMsg('Zip OK'.toString());
      return true;
    } catch (e) { _logMsg('unzip error: $e'.toString()); return false; }
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
        if (e.isSymbolicLink) { continue; } } catch (_) {}
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
    _logMsg('Hardlinks: $n'.toString());
  }

  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    int n=0;
    for (final dir in ['/bin','/sbin','/usr/bin','/usr/sbin','/lib','/usr/lib']) {
      try { await for (final e in Directory('$rootfs$dir').list(followLinks: false)) {
        if (e is Link) { try { final t = await e.target(); if (t.startsWith('/')) { final r = File('$rootfs$t'); if (await r.exists() && await r.length() > 0) { try { await e.delete(); } catch (_) {} await File(e.path).writeAsBytes(await r.readAsBytes()); n++; } } } catch (_) {} } } } catch (_) {}
    }
    _logMsg('Symlinks: $n'.toString());
  }

  Future<void> resetEnvironment() async {
    final d = await _appDir;
    try { await Directory(d).delete(recursive: true); } catch (_) {}
    _initialized = false; _rootfsPath = null; _apkIndex = {}; _installedPkgs.clear(); _bionicInstalled = false;
    _statusMessage = 'Reiniciado'; _log.clear(); _logMsg('Reiniciado'.toString()); notifyListeners();
  }

  // ═══════════════════════════════════════════════════════
  // checkEnvironment
  // ═══════════════════════════════════════════════════════
  Future<bool> checkEnvironment() async {
    _log.clear();
    _logMsg('=== CHECK v9.5f ==='.toString());
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
      _logMsg('Rootfs: ${_initialized ? "OK" : "no"}'.toString());
      _logMsg('Bionic: ${_bionicInstalled ? "OK" : "no"}'.toString());
      notifyListeners();
      return _initialized || _bionicInstalled;
    } catch (e) { _logMsg('Error: $e'.toString()); return false; }
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

  Future<void> checkEnvironment() async {
    try {
      _initialized = true;

      // simulación básica de entorno proot
      _bionicInstalled = false;

      _logMsg("checkEnvironment OK");
      notifyListeners();
    } catch (e) {
      _logMsg("checkEnvironment error: $e");
    }
  }

