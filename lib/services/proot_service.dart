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
    debugPrint('ProotSetup: $msg');
  }

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;

  String? _rootfsPath;

  static const String _minirootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz';
  static const String _debianRootfsUrl =
      'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.tar.xz';
  static const String _prootRsUrl =
      'https://github.com/proot-me/proot-rs/releases/download/v0.1.0/proot-rs-v0.1.0-aarch64-linux-android.tar.gz';

  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

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
          if (st.size > 0) {
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

      bool ok = false;

      // 1: Asset embeebido (Alpine 3.24.1)
      ok = await _setupFromAsset(rootfs);
      if (ok) { _logMsg('✓ Rootfs extraído desde asset'); }

      // 2: Minirootfs descargado
      if (!ok) {
        ok = await _setupWithMinirootfs(appDir, rootfs);
        if (ok) { _logMsg('✓ Rootfs desde minirootfs'); }
      }

      // 3: Debian
      if (!ok) {
        ok = await _setupWithDebianRootfs(appDir, rootfs);
        if (ok) { _logMsg('✓ Rootfs Debian'); }
      }

      if (!ok) { throw Exception('No se pudo crear el rootfs'); }

      // ─── Post: reparar hardlinks (copiar busybox a archivos 0 bytes) ───
      _logMsg('Reparando hardlinks…');
      await _fixHardlinks(rootfs);

      // ─── DNS ───
      _downloadProgress = 0.80;
      _statusMessage = 'Configurando red…';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      if (await File('$rootfs/etc/apt').exists()) {
        _logMsg('Rootfs Debian, configurando apt');
        final aptDir = Directory('$rootfs/etc/apt');
        await aptDir.create(recursive: true);
        if (!await File('$rootfs/etc/apt/sources.list').exists()) {
          await File('$rootfs/etc/apt/sources.list').writeAsString(
            'deb http://deb.debian.org/debian bookworm main contrib non-free\n'
            'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free\n'
            'deb http://deb.debian.org/debian bookworm-updates main contrib non-free\n');
        }
      }

      // ─── Permisos ───
      await _chmodBins(rootfs);

      // ─── PROOT-rs ───
      _downloadProgress = 0.90;
      _statusMessage = 'Descargando PROOT-rs…';
      notifyListeners();
      await _downloadProotRs(appDir);

      // ─── Verificacion (repara symlinks absolutos de Alpine) ───
      await _fixAbsoluteSymlinks(rootfs);

      bool shOk = false;

      // Buscar shell disponible
      for (final candidate in ['$rootfs/bin/sh', '$rootfs/bin/busybox', '$rootfs/bin/dash']) {
        try {
          final f = File(candidate);
          if (await f.exists() && await f.length() > 0) {
            shOk = true;
            // Si no es /bin/sh, copiarlo
            if (candidate != '$rootfs/bin/sh') {
              try {
                final target = File('$rootfs/bin/sh');
                try { if (await Link(target.path).exists()) await Link(target.path).delete(); } catch (_) {}
                try { if (await target.exists()) await target.delete(); } catch (_) {}
                await target.writeAsBytes(await f.readAsBytes());
                _logMsg('/bin_sh copiado desde ' + candidate.split('/').last + ' (' + (await target.length()).toString() + ' b)');
              } catch (e) {
                _logMsg('No se pudo copiar a /bin/sh: $e');
              }
            }
            break;
          }
        } catch (_) { continue; }
      }

      // Ultimo recurso: cualquier binario del rootfs
      if (!shOk) {
        for (final dir in ['/bin', '/sbin', '/usr/bin']) {
          final d = Directory('$rootfs$dir');
          if (!await d.exists()) continue;
          try {
            await for (final entity in d.list(followLinks: false)) {
              if (entity is File && await entity.length() > 1000) {
                await File('$rootfs/bin/sh').writeAsBytes(await entity.readAsBytes());
                shOk = true;
                _logMsg('/bin/sh creado desde binario (' + (await File('$rootfs/bin/sh').length()).toString() + ' b)');
                break;
              }
            }
          } catch (_) {}
          if (shOk) break;
        }
      }

      _downloadProgress = 1.0;
      _initialized = shOk;
      if (shOk) {
        _statusMessage = 'Linux listo - Instalando paquetes esenciales...';
        _logMsg(_statusMessage);
        notifyListeners();

        // Instalar paquetes esenciales post-setup
        await installEssentials();

        _statusMessage = 'Linux listo - Todo instalado';
        _logMsg(_statusMessage);
      } else {
        _statusMessage = 'Error: /bin/sh no encontrado en rootfs';
        _logMsg(_statusMessage);
      }
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

    // ────────── Asset: system tar + archive fallback ──────────
  Future<bool> _setupFromAsset(String rootfs) async {
    _logMsg('--- Buscando assets embebidos ---');
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      if (!manifest.contains('assets/rootfs.tar.gz')) {
        _logMsg('No hay asset de rootfs en el APK');
        return false;
      }

      _logMsg('Leyendo asset: assets/rootfs.tar.gz');
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      final bytes = data.buffer.asUint8List();

      // Guardar a archivo temporal para system tar
      final appDir = await _appDir;
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      await File(tarPath).writeAsBytes(bytes);

      // Intentar system tar primero (maneja symlinks y hardlinks nativamente)
      for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
        if (await File(tb).exists()) {
          try {
            _logMsg('Extrayendo con $tb tar');
            final result = await Process.run(
              tb, ['tar', '-xzf', tarPath, '-C', rootfs],
            ).timeout(const Duration(seconds: 180));
            if (result.exitCode == 0) {
              if (await File('$rootfs/bin/sh').exists() &&
                  await File('$rootfs/bin/sh').length() > 0) {
                _logMsg('OK: /bin/sh extraido con $tb');
                return true;
              }
              if (await File('$rootfs/bin/busybox').exists() &&
                  await File('$rootfs/bin/busybox').length() > 0) {
                _logMsg('OK: busybox extraido con $tb');
                return true;
              }
              _logMsg('system tar extrajo pero /bin/sh no encontrado');
            }
          } catch (e) {
            _logMsg('system tar fallo: $e');
          }
        }
      }

      // Fallback: archive package Dart con multi-pasada
      _logMsg('Fallback: archive package Dart');
      final gzBytes = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gzBytes);
      _logMsg('Total entradas: ${archive.length}');

      int dirs = 0, files = 0, symlinksDeferred = 0, emptyFiles = 0;
      final deferred = <MapEntry<String, String>>[]; // [path, target]

      // PASADA 1: directorios + archivos (no symlinks)
      for (final entry in archive) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name.isEmpty || name == '.') continue;
        final outPath = '$rootfs/$name';

        if (name.endsWith('/')) {
          await Directory(outPath).create(recursive: true);
          dirs++; continue;
        }
        await Directory(outPath).parent.create(recursive: true);

        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink ?? '';
          if (target.isNotEmpty) deferred.add(MapEntry(outPath, target));
          symlinksDeferred++;
          continue;
        }

        if (entry.isFile) {
          final content = entry.content as List<int>;
          if (content.isNotEmpty) {
            try { if (await Link(outPath).exists()) await Link(outPath).delete(); } catch (_) {}
            await File(outPath).writeAsBytes(content);
            files++;
          } else {
            await File(outPath).writeAsBytes([]); // hardlink placeholder
            emptyFiles++;
          }
        }
      }
      _logMsg('1a pasada: $dirs dirs, $files archivos, $symlinksDeferred symlinks, $emptyFiles hardlinks');

      // PASADA 2: symlinks -> copiar contenido del target
      int symlinksOk = 0;
      for (final me in deferred) {
        final outPath = me.key;
        String target = me.value.replaceAll('//', '/');
        final resolved = target.startsWith('/')
            ? '$rootfs$target'
            : '${Directory(outPath).parent.path}/$target';

        if (await File(resolved).exists() && await File(resolved).length() > 0) {
          try { await File(outPath).writeAsBytes(await File(resolved).readAsBytes()); symlinksOk++; continue; } catch (_) {}
        }
        try { await Link(outPath).create(target); symlinksOk++; } catch (_) {}
      }
      _logMsg('2a pasada: $symlinksOk/$symlinksDeferred symlinks procesados');

      // PASADA 3: hardlinks -> copiar desde busybox
      int hardlinksFixed = 0;
      final bb = File('$rootfs/bin/busybox');
      List<int>? bbData;
      if (await bb.exists() && await bb.length() > 0) bbData = await bb.readAsBytes();

      final muslLibs = <String, List<int>>{};
      for (final lib in ['ld-musl-aarch64.so.1', 'libc.musl-aarch64.so.1']) {
        final lf = File('$rootfs/lib/$lib');
        if (await lf.exists() && await lf.length() > 0) muslLibs[lib] = await lf.readAsBytes();
      }

      for (final scanDir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
        final d = Directory('$rootfs$scanDir');
        if (!await d.exists()) continue;
        try {
          await for (final entity in d.list(followLinks: false)) {
            if (entity is File && await entity.length() == 0) {
              final path = entity.path;
              if (bbData != null && (path.contains('/bin/') || path.contains('/sbin/'))) {
                await entity.writeAsBytes(bbData); hardlinksFixed++;
              } else if (path.contains('/lib/') && muslLibs.isNotEmpty) {
                for (final le in muslLibs.entries) {
                  if (path.endsWith(le.key)) break;
                  if (path.contains('ld-musl') && muslLibs.containsKey('libc.musl-aarch64.so.1')) {
                    await entity.writeAsBytes(muslLibs['libc.musl-aarch64.so.1']!); hardlinksFixed++;
                  } else if (path.contains('libc.musl') && muslLibs.containsKey('ld-musl-aarch64.so.1')) {
                    await entity.writeAsBytes(muslLibs['ld-musl-aarch64.so.1']!); hardlinksFixed++;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }
      _logMsg('3a pasada: $hardlinksFixed hardlinks reparados');

      // Asegurar /bin/sh
      if (bbData != null && (!await File('$rootfs/bin/sh').exists() || await File('$rootfs/bin/sh').length() == 0)) {
        await File('$rootfs/bin/sh').writeAsBytes(bbData);
        _logMsg('Creado /bin/sh desde busybox');
      }

      final hasSh = await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0;
      _logMsg(hasSh ? 'OK: /bin/sh presente' : 'ERROR: /bin/sh ausente');
      return hasSh;
    } catch (e) {
      _logMsg('Asset fallo: $e');
      return false;
    }
  }

  // ──────────// ────────── Reparar hardlinks ──────────
  Future<void> _fixHardlinks(String rootfs) async {
    // Buscar busybox
    final bbPath = '$rootfs/bin/busybox';
    List<int>? bbData;
    if (await File(bbPath).exists() && await File(bbPath).length() > 0) {
      bbData = await File(bbPath).readAsBytes();
    }

    // Buscar librerias musl
    final muslLibs = <String, List<int>>{};
    for (final lib in ['ld-musl-aarch64.so.1', 'libc.musl-aarch64.so.1']) {
      final f = File('$rootfs/lib/$lib');
      if (await f.exists() && await f.length() > 0) {
        muslLibs[lib] = await f.readAsBytes();
      }
    }

    int fixed = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) { continue; }
      try {
        await for (final entity in d.list(followLinks: false)) {
          if (entity is File) {
            try {
              if (await entity.length() == 0) {
                final path = entity.path;
                // bin/ -> copiar busybox
                if (bbData != null && (path.contains('/bin/') || path.contains('/sbin/'))) {
                  await entity.writeAsBytes(bbData); fixed++;
                }
                // lib/ -> copiar musl lib
                if (path.contains('/lib/') && muslLibs.isNotEmpty) {
                  for (final me in muslLibs.entries) {
                    if (path.endsWith(me.key)) break;
                    if (path.contains('ld-musl') && muslLibs.containsKey('libc.musl-aarch64.so.1')) {
                      await entity.writeAsBytes(muslLibs['libc.musl-aarch64.so.1']!); fixed++;
                    } else if (path.contains('libc.musl') && muslLibs.containsKey('ld-musl-aarch64.so.1')) {
                      await entity.writeAsBytes(muslLibs['ld-musl-aarch64.so.1']!); fixed++;
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    // Asegurar /bin/sh
    if (bbData != null) {
      final shFile = File('$rootfs/bin/sh');
      if (!await shFile.exists() || await shFile.length() == 0) {
        try { await shFile.writeAsBytes(bbData); _logMsg('Creado /bin/sh desde busybox'); fixed++; } catch (_) {}
      }
    }

    _logMsg('Hardlinks reparados: $fixed');
  }

  // ────────── Minirootfs descargado ──────────
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    _logMsg('--- Minirootfs descargado ---');
    _statusMessage = 'Descargando Alpine…';
    notifyListeners();

    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try {
        await _downloadFile(_minirootfsUrl, tgzPath, 0.20, 0.50);
      } catch (e) {
        _logMsg('ERROR descarga: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo Alpine…';
    notifyListeners();

    // Intentar system tar primero
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          _logMsg('Extrayendo Alpine con $tb');
          final result = await Process.run(
            tb, ['tar', '-xzf', tgzPath, '-C', rootfs],
          ).timeout(const Duration(seconds: 180));
          if (result.exitCode == 0) {
            await _fixAbsoluteSymlinks(rootfs);
            if (await File('$rootfs/bin/sh').exists() && await File('$rootfs/bin/sh').length() > 0) {
              _logMsg('Alpine extraido con $tb');
              return true;
            }
            if (await File('$rootfs/bin/busybox').exists() && await File('$rootfs/bin/busybox').length() > 0) {
              if (!await File('$rootfs/bin/sh').exists() || await File('$rootfs/bin/sh').length() == 0) {
                try {
                  final target = File('$rootfs/bin/sh');
                  try { if (await Link(target.path).exists()) await Link(target.path).delete(); } catch (_) {}
                  try { if (await target.exists()) await target.delete(); } catch (_) {}
                  await target.writeAsBytes(await File('$rootfs/bin/busybox').readAsBytes());
                } catch (_) {}
              }
              _logMsg('busybox extraido con $tb');
              return true;
            }
          }
        } catch (e) {
          _logMsg('$tb tar fallo: $e');
        }
      }
    }

    // Fallback archive package
    _logMsg('Usando archive package Dart');
    return _extractTarDart(tgzPath, rootfs);
  }

  // ────────── Debian ──────────
  Future<bool> _setupWithDebianRootfs(String appDir, String rootfs) async {
    _logMsg('--- Debian rootfs ---');
    _statusMessage = 'Descargando Debian…';
    notifyListeners();

    final xzPath = '$appDir/debian-rootfs.tar.xz';
    if (!await File(xzPath).exists()) {
      try {
        await _downloadFile(_debianRootfsUrl, xzPath, 0.20, 0.50);
      } catch (e) {
        _logMsg('ERROR descarga: $e');
        return false;
      }
    }

    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo Debian…';
    notifyListeners();

    // Toybox para .tar.xz (Dart no maneja XZ)
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          await Process.run(tb, ['tar', '-xf', xzPath, '-C', rootfs])
              .timeout(const Duration(seconds: 180));
          if (await File('$rootfs/bin/sh').exists() &&
              await File('$rootfs/bin/sh').length() > 0) { return true; }
        } catch (e) { _logMsg('$tb falló: $e'); }
      }
    }
    return false;
  }

  // ────────── Extraer tar.gz con archive package ──────────
  Future<bool> _extractTarDart(String tgzPath, String rootfs) async {
    try {
      final bytes = await File(tgzPath).readAsBytes();
      final gz = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gz);

      
      for (final entry in archive) {
        String name = entry.name;
        if (name.startsWith('./')) { name = name.substring(2); }
        if (name.isEmpty || name == '.') { continue; }

        final outPath = '$rootfs/$name';

        if (name.endsWith('/')) {
          await Directory(outPath).create(recursive: true);
          continue;
        }

        await Directory(outPath).parent.create(recursive: true);

        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink;
          if (target != null && target.isNotEmpty) {
            final resolved = target.startsWith('/')
                ? '$rootfs$target'
                : '${Directory(outPath).parent.path}/$target';
            if (await File(resolved).exists()) {
              try { await File(resolved).copy(outPath); } catch (_) {}
            }
          }
          continue;
        }

        if (entry.isFile) {
          final content = entry.content;
          if (content.isNotEmpty) {
            await File(outPath).writeAsBytes(content);
          } else {
            await File(outPath).writeAsString('');
          }
          continue;
        }
        
      }
      return true;
    } catch (e) {
      _logMsg('Error extracción Dart: $e');
      return false;
    }
  }

  // ────────── Permisos ──────────
  Future<void> _chmodBins(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (await d.exists()) {
        try {
          await for (final entity in d.list()) {
            if (entity is File) {
              try {
                await Process.run('chmod', ['755', entity.path])
                    .timeout(const Duration(seconds: 5));
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }
  }

  // ────────── Arreglar symlinks absolutos de Alpine ──────────
  /// Los rootfs de Alpine usan symlinks absolutos (ej: /bin/sh -> /bin/busybox).
  /// Al extraerlos con system tar, estos apuntan al sistema Android, no al rootfs.
  /// Esta funcion convierte los symlinks rotos en archivos reales.
  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    final targetDirs = ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib'];
    int fixed = 0;

    for (final dir in targetDirs) {
      final d = Directory('\$rootfs\$dir');
      if (!await d.exists()) continue;
      try {
        await for (final entity in d.list(followLinks: false)) {
          if (entity is Link) {
            try {
              final target = await entity.target();
              if (target.startsWith('/')) {
                // Symlink absoluto -> resolver dentro del rootfs
                final resolved = '\$rootfs\$target';
                final resolvedFile = File(resolved);
                if (await resolvedFile.exists() && await resolvedFile.length() > 0) {
                  final data = await resolvedFile.readAsBytes();
                  // Reemplazar symlink con archivo real
                  try { await entity.delete(); } catch (_) {}
                  await File(entity.path).writeAsBytes(data);
                  fixed++;
                }
              } else {
                // Symlink relativo -> resolver desde el directorio del symlink
                final parent = Directory(entity.path).parent.path;
                final resolved = '\$parent/\$target'.replaceAll(RegExp(r'/+'), '/');
                final resolvedFile = File(resolved);
                if (await resolvedFile.exists() && await resolvedFile.length() > 0) {
                  final data = await resolvedFile.readAsBytes();
                  try { await entity.delete(); } catch (_) {}
                  await File(entity.path).writeAsBytes(data);
                  fixed++;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    _logMsg('Symlinks absolutos reparados: $fixed');
  }

  // ────────── PROOT-rs ──────────  // ────────── PROOT-rs ──────────
  Future<void> _downloadProotRs(String appDir) async {
    final prootPath = '$appDir/proot';
    if (await File(prootPath).exists()) { _logMsg('PROOT-rs ya existe'); return; }
    try {
      _logMsg('Descargando PROOT-rs (tar.gz)');
      final tgzPath = '$appDir/proot-rs.tar.gz';
      await _downloadFile(_prootRsUrl, tgzPath, 0.85, 0.92);

      // Extraer binario del tar.gz
      final bytes = await File(tgzPath).readAsBytes();
      try {
        final gz = GZipDecoder().decodeBytes(bytes);
        final archive = TarDecoder().decodeBytes(gz);
        for (final entry in archive) {
          if (entry.isFile && entry.content.length > 100000) {
            await File(prootPath).writeAsBytes(entry.content);
            await Process.run('chmod', ['755', prootPath]);
            _logMsg('PROOT-rs extraido: ${entry.content.length} bytes');
            try { await File(tgzPath).delete(); } catch (_) {}
            return;
          }
        }
        _logMsg('No se encontro binario en tar.gz');
      } catch (e) {
        _logMsg('Error extrayendo proot-rs tar.gz: $e');
        // Fallback: binario directo
        final size = await File(tgzPath).length();
        if (size > 100000) {
          await File(tgzPath).copy(prootPath);
          await Process.run('chmod', ['755', prootPath]);
          _logMsg('PROOT-rs copiado directamente: $size bytes');
        }
      }
    } catch (e) {
      _logMsg('PROOT-rs no disponible: $e');
    }
  }

  // ────────── runCommand ──────────
    Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\nPulsa "Setup Linux" primero.\n';
    }

    final rootfs = _rootfsPath!;
    final appDir = await _appDir;
    final linker = await _linker;

    // Buscar el shell del rootfs
    String? shellPath;
    for (final p in ['$rootfs/bin/sh', '$rootfs/bin/busybox', '$rootfs/bin/dash', '$rootfs/bin/bash']) {
      try {
        if (await File(p).exists() && await File(p).length() > 0) { shellPath = p; break; }
      } catch (_) { continue; }
    }
    if (shellPath == null) {
      return 'Error: No hay shell disponible en rootfs.\n';
    }

    try {
      // ───       // ─── ESTRATEGIA 1: PROOT-rs (la mejor opcion) ───
      final prootPath = '$appDir/proot';
      if (linker != null && await File(prootPath).exists() && await File(prootPath).length() > 0) {
        try {
          _logMsg('Ejecutando via proot-rs: ' + command);
          final result = await Process.run(
            linker,
            [prootPath, '-r', rootfs, '--', '/bin/sh', '-c', command],
            environment: {
              'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
              'HOME': '/root',
              'TERM': 'xterm-256color',
              'LD_LIBRARY_PATH': '/lib:/usr/lib',
            },
          ).timeout(timeout);
          final out = result.stdout as String;
          final err = result.stderr as String;
          if (result.exitCode != 0) {
            _logMsg('proot-rs exit code: ' + result.exitCode.toString());
          }
          if (err.isNotEmpty) {
            _lastOutput = err;
            if (out.isNotEmpty) _lastOutput += '\n' + out;
            _logMsg('proot-rs stderr: ' + err);
          } else {
            _lastOutput = out;
          }
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'proot-rs fallo: ' + e.toString() + '\n';
          _logMsg('proot-rs catch: ' + e.toString());
        }
      }

      // ─── ESTRATEGIA 2: Linker del sistema + shellESTRATEGIA 2: Linker del sistema + shell rootfs ───
      if (linker != null) {
        try {
          final result = await Process.run(
            linker, [shellPath, '-c', command],
            environment: {
              'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                      '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                      ':/system/bin:/system/xbin',
              'HOME': '/root',
              'TERM': 'xterm-256color',
              'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
            },
            workingDirectory: rootfs,
          ).timeout(timeout);
          final out = result.stdout as String;
          final err = result.stderr as String;
          _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
          return _lastOutput;
        } catch (e) {
          _lastOutput = 'linker fallo: $e\n';
        }
      }

      // ─── ESTRATEGIA 3: Shell del sistema + PATH al rootfs ───
      if (await File('/system/bin/sh').exists()) {
        final result = await Process.run(
          '/system/bin/sh', ['-c', command],
          environment: {
            'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                    '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                    ':/system/bin:/system/xbin',
            'HOME': '/root',
            'TERM': 'xterm-256color',
            'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
          },
        ).timeout(timeout);
        final out = result.stdout as String;
        final err = result.stderr as String;
        _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
        return _lastOutput;
      }

      // ─── ESTRATEGIA 4: Ejecucion directa del shell rootfs ───
      final result = await Process.run(
        shellPath, ['-c', command],
        environment: {
          'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
          'HOME': '/root',
          'TERM': 'xterm-256color',
        },
        workingDirectory: rootfs,
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException {
      return '\n[Timeout] ${timeout.inSeconds}s excedido\n';
    } catch (e) {
      _lastOutput = '\n[Error] $e\n';
      _statusMessage = 'Error de ejecucion';
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
      if (response.statusCode != 200) { throw Exception('HTTP ${response.statusCode}'); }
      final total = response.contentLength;
      int recv = 0;
      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        recv += chunk.length;
        if (total > 0) {
          _downloadProgress = sw + (recv / total) * (ew - sw);
          if (recv % (1024 * 512) < chunk.length) { notifyListeners(); }
        }
      }
      await sink.flush();
      await sink.close();
      _logMsg('OK: $recv bytes');
    } finally { client.close(); }
  }

  // ────────── Instalar paquetes esenciales ──────────
  Future<void> installEssentials() async {
    _logMsg('Actualizando repositorios apk...');
    _statusMessage = 'Actualizando repositorios...';
    notifyListeners();
    try {
      final update = await runCommand('apk update 2>&1 || true',
          timeout: const Duration(seconds: 120));
      _logMsg('apk update: ${update.length > 200 ? update.substring(0, 200) + "..." : update}');
    } catch (e) {
      _logMsg('apk update fallo: $e');
    }

    _statusMessage = 'Instalando openssh-server...';
    notifyListeners();
    try {
      final ssh = await runCommand(
        'apk add openssh-server openssh-keygen 2>&1 || true',
        timeout: const Duration(seconds: 180));
      _logMsg('openssh: ${ssh.length > 100 ? ssh.substring(0, 100) + "..." : ssh}');
    } catch (e) {
      _logMsg('openssh fallo: $e');
    }

    _statusMessage = 'Instalando curl wget bash ca-certificates...';
    notifyListeners();
    try {
      final utils = await runCommand(
        'apk add curl wget bash ca-certificates sudo nano 2>&1 || true',
        timeout: const Duration(seconds: 180));
      _logMsg('utilidades: ${utils.length > 100 ? utils.substring(0, 100) + "..." : utils}');
    } catch (e) {
      _logMsg('utilidades fallo: $e');
    }

    // Generar claves SSH y configurar
    _statusMessage = 'Configurando SSH...';
    notifyListeners();
    try {
      // Generar claves de host SSH
      final keys = await runCommand(
        'ssh-keygen -A 2>&1 || true',
        timeout: const Duration(seconds: 30));
      if (keys.isNotEmpty) _logMsg('ssh-keys: ${keys.substring(0, keys.length > 60 ? 60 : keys.length)}');

      // Configurar sshd para permitir root
      final config = await runCommand(
        'sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config 2>/dev/null; '
        'sed -i "s/#PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config 2>/dev/null; '
        'echo "root:linux" | chpasswd 2>/dev/null || true; '
        'echo "SSH configurado"',
        timeout: const Duration(seconds: 10));
      _logMsg(config);

      // Arrancar SSH
      final start = await runCommand(
        '/usr/sbin/sshd 2>&1 || /usr/sbin/sshd -p 2222 2>&1 || echo "sshd ya en ejecucion"',
        timeout: const Duration(seconds: 10));
      _logMsg('sshd: $start');
    } catch (e) {
      _logMsg('config ssh fallo: $e');
    }

    _statusMessage = 'Paquetes esenciales instalados';
    _logMsg('Paquetes esenciales OK');
    notifyListeners();
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
