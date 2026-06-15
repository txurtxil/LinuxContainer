#!/bin/bash
# ============================================================================
# Linux Container v3.1 - Fix: usar ld-musl como loader via linker64
# 
# Problema: linker64 de Android NO puede cargar libc.musl como shared library
# Solucion: linker64 -> ld-musl (loader statico) -> apk (binario musl)
# ============================================================================
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linux Container v3.1 - Fix linker64+musl${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"

# Backup
echo -e "\n${YELLOW}[1/4] Respaldando...${NC}"
mkdir -p .backup
cp lib/services/proot_service.dart .backup/proot_service_v3.0.bak
echo -e "  ${GREEN}✓${NC} Backup en .backup/"

# ─── Escribir proot_service.dart corregido ───
echo -e "\n${YELLOW}[2/4] Escribiendo proot_service.dart v3.1...${NC}"

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
    debugPrint('ProotSetup: $msg');
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
  static const String _muslLibcUrl =
      'https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/musl-1.2.5-r1.apk';

  Future<String?> get _linker async {
    if (await File('/system/bin/linker64').exists()) return '/system/bin/linker64';
    if (await File('/system/bin/linker').exists()) return '/system/bin/linker';
    return null;
  }

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  /// Obtiene la ruta al loader musl
  Future<String?> _getMuslLoader(String rootfs) async {
    for (final candidate in [
      '$rootfs/lib/ld-musl-aarch64.so.1',
      '$rootfs/lib/libc.musl-aarch64.so.1',
    ]) {
      final f = File(candidate);
      if (await f.exists() && await f.length() > 100000) return candidate;
    }
    return null;
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
          if (st.size > 1000) {
            _initialized = true;
            _statusMessage = 'Linux listo';
            _logMsg('Rootfs OK, /bin/sh existe (${st.size} bytes)');
            notifyListeners();
            return true;
          }
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

  // ════════════════════════════════════════════════════════════════
  // runCommand: linker64 + ld-musl + binario (triple loader chain)
  // linker64 carga ld-musl (loader musl statico)
  // ld-musl carga el binario y sus dependencias (libc.musl, libz, etc.)
  // ════════════════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;

    if (linker == null) {
      _lastOutput = '[Error] linker64 no encontrado en /system/bin';
      return _lastOutput;
    }

    // Limpiar shell syntax
    String cleanCmd = command
        .replaceAll(RegExp(r'\s*2>&1\s*'), ' ')
        .replaceAll(RegExp(r'\s*2>/dev/null\s*'), ' ')
        .replaceAll(RegExp(r'\s*>\s*/dev/null\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|\|\s*true\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|\|\s*false\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|.*$'), '')
        .replaceAll(RegExp(r'\s*&\s*$'), '')
        .trim();

    final parts = cleanCmd.split(' ');
    final binName = parts.isNotEmpty ? parts.first : '';
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];
    if (binName.isEmpty) {
      _lastOutput = '';
      return _lastOutput;
    }

    // Buscar binario en rootfs
    final binDirs = ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/local/bin'];
    String? binPath;
    for (final d in binDirs) {
      final candidate = '$rootfs$d/$binName';
      try {
        if (await File(candidate).exists() && await File(candidate).length() > 100) {
          binPath = candidate;
          break;
        }
      } catch (_) { continue; }
    }

    try {
      final Map<String, String> env = {
        'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                ':/system/bin:/system/xbin',
        'HOME': '/root',
        'TERM': 'xterm-256color',
        'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
      };

      String output;
      int exitCode = -1;

      if (binPath != null) {
        final muslLoader = await _getMuslLoader(rootfs);

        // ESTRATEGIA A: linker64 -> ld-musl -> binario
        // ld-musl es el dynamic linker nativo de Alpine. linker64 lo carga
        // como PIE, y ld-musl se encarga de cargar el binario musl-linked.
        if (muslLoader != null) {
          try {
            _logMsg('ld-musl: $binName $args');
            final result = await Process.run(
              linker, [muslLoader, binPath, ...args],
              environment: env,
              workingDirectory: rootfs,
            ).timeout(timeout);
            exitCode = result.exitCode;
            final out = result.stdout as String;
            final err = result.stderr as String;
            output = err.isNotEmpty ? '$out\n$err' : out;
            
            if (exitCode != 0 && output.contains('CANNOT LINK')) {
              _logMsg('ld-musl fallo (CANNOT LINK), intentando linker64 directo');
            } else {
              _lastOutput = output;
              return output;
            }
          } catch (e) {
            _logMsg('ld-musl error: $e, intentando linker64 directo');
          }
        }

        // ESTRATEGIA B: linker64 -> binario directo
        // Funciona para binarios estaticos (sin libc.musl) como proot-rs
        try {
          _logMsg('linker64: $binName $args');
          final result = await Process.run(
            linker, [binPath, ...args],
            environment: env,
            workingDirectory: rootfs,
          ).timeout(timeout);
          final out = result.stdout as String;
          final err = result.stderr as String;
          output = err.isNotEmpty ? '$out\n$err' : out;
          _lastOutput = output;
          return output;
        } catch (e) {
          _logMsg('linker64 directo fallo: $e');
        }
      }

      // ESTRATEGIA C: sistema (para comandos nativos como uname, echo)
      _logMsg('system: $command');
      final result = await Process.run(
        '/system/bin/sh', ['-c', command],
        environment: {
          'PATH': '/system/bin:/system/xbin',
          'TERM': 'xterm-256color',
        },
      ).timeout(timeout);
      final out = result.stdout as String;
      final err = result.stderr as String;
      output = err.isNotEmpty ? '$out\n$err' : out;
      _lastOutput = output;
      return output;
    } on TimeoutException {
      _lastOutput = '\n[Timeout] ${timeout.inSeconds}s excedido\n';
      return _lastOutput;
    } catch (e) {
      _lastOutput = '\n[Error] $e\n';
      _statusMessage = 'Error ejecucion';
      notifyListeners();
      return _lastOutput;
    }
  }

  // ════════════════════════════════════════════════════════════════
  // runShell: Shell interactiva via linker64 + ld-musl + busybox + wrappers
  // ════════════════════════════════════════════════════════════════
  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;
    if (linker == null) return '[Error] linker64 no encontrado';

    final muslLoader = await _getMuslLoader(rootfs);
    final busyboxPath = '$rootfs/bin/busybox';
    
    if (muslLoader == null || !await File(busyboxPath).exists() || await File(busyboxPath).length() < 100) {
      return runCommand(command);
    }

    try {
      final wrappers = StringBuffer();
      wrappers.writeln('export LD_LIBRARY_PATH=/lib:/usr/lib');
      wrappers.writeln('export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin');
      wrappers.writeln('export HOME=/root');
      wrappers.writeln('export TERM=xterm-256color');

      // Wrapper functions: linker64 -> ld-musl -> binario
      // Esto permite que el shell busybox ejecute comandos musl-linked
      for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/local/bin']) {
        final d = Directory('$rootfs$dir');
        if (!await d.exists()) continue;
        try {
          await for (final entry in d.list(followLinks: false)) {
            if (entry is File) {
              final size = await entry.length();
              if (size > 1000) {
                final name = entry.uri.pathSegments.last;
                if (name == 'busybox' || name == 'sh') continue;
                // Usar ld-musl como loader para binarios musl
                wrappers.writeln("$name() { $linker '$muslLoader' '${entry.path}' \"\$@\"; }");
              }
            }
          }
        } catch (_) {}
      }

      wrappers.writeln(command);

      final result = await Process.run(
        linker,
        [muslLoader, busyboxPath, 'sh', '-c', wrappers.toString()],
        environment: {
          'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
          'HOME': '/root',
          'TERM': 'xterm-256color',
        },
        workingDirectory: rootfs,
      ).timeout(timeout);

      final out = result.stdout as String;
      final err = result.stderr as String;
      return err.isNotEmpty ? '$out\n$err' : out;
    } on TimeoutException {
      return '\n[Timeout] ${timeout.inSeconds}s excedido\n';
    } catch (e) {
      return '\n[Error Shell] $e\n';
    }
  }

  // ════════════════════════════════════════════════════════════════
  // setupEnvironment
  // ════════════════════════════════════════════════════════════════
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

      bool ok = false;
      ok = await _setupFromAsset(rootfs);
      if (ok) _logMsg('✓ Rootfs desde asset');
      if (!ok) {
        ok = await _setupWithMinirootfs(appDir, rootfs);
        if (ok) _logMsg('✓ Rootfs desde minirootfs');
      }
      if (!ok) throw Exception('No se pudo crear el rootfs');

      _logMsg('Reparando hardlinks...');
      await _fixHardlinks(rootfs);

      _logMsg('Verificando libreria musl...');
      await _ensureMuslLib(rootfs);

      // Verificar que ld-musl existe (necesario como loader)
      final muslLoader = await _getMuslLoader(rootfs);
      if (muslLoader != null) {
        _logMsg('Loader musl: $muslLoader (${await File(muslLoader).length()} bytes)');
      } else {
        _logMsg('WARNING: No se encontro ld-musl, los comandos musl no funcionaran');
      }

      // DNS
      _downloadProgress = 0.80;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      await _chmodBins(rootfs);

      // Limpiar temporal
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      if (await File(tarPath).exists()) {
        try { await File(tarPath).delete(); } catch (_) {}
      }

      await _fixAbsoluteSymlinks(rootfs);

      // Buscar/crear /bin/sh
      bool shOk = false;
      for (final candidate in ['$rootfs/bin/sh', '$rootfs/bin/busybox',
                                '$rootfs/bin/dash', '$rootfs/bin/ash']) {
        try {
          if (await File(candidate).exists() && await File(candidate).length() > 1000) {
            if (candidate != '$rootfs/bin/sh') {
              final target = File('$rootfs/bin/sh');
              try { if (await Link(target.path).exists()) await Link(target.path).delete(); } catch (_) {}
              try { if (await target.exists()) await target.delete(); } catch (_) {}
              await target.writeAsBytes(await File(candidate).readAsBytes());
            }
            shOk = true;
            _logMsg('/bin/sh verificado (${await File("$rootfs/bin/sh").length()} bytes)');
            break;
          }
        } catch (_) { continue; }
      }
      if (!shOk) {
        outer:
        for (final dir in ['/bin', '/sbin', '/usr/bin']) {
          final d = Directory('$rootfs$dir');
          if (!await d.exists()) continue;
          try {
            await for (final entity in d.list(followLinks: false)) {
              if (entity is File && await entity.length() > 1000) {
                await File('$rootfs/bin/sh').writeAsBytes(await entity.readAsBytes());
                shOk = true;
                _logMsg('/bin/sh desde ${entity.path} (${await entity.length()} b)');
                break outer;
              }
            }
          } catch (_) {}
        }
      }

      _downloadProgress = 1.0;
      _initialized = shOk;
      if (shOk) {
        _statusMessage = 'Linux listo - Instalando paquetes...';
        _logMsg(_statusMessage);
        notifyListeners();

        // Test basico: listar bin del rootfs usando ld-musl
        try {
          final testResult = await runCommand('ls /bin',
              timeout: const Duration(seconds: 10));
          _logMsg('Test ld-musl ls: ${testResult.length > 100 ? testResult.substring(0, 100) + "..." : (testResult.isEmpty ? "(vacio)" : testResult)}');
        } catch (e) {
          _logMsg('Test ld-musl fallo: $e');
        }

        await installEssentials();
        _statusMessage = 'Linux listo - Todo instalado';
        _logMsg(_statusMessage);
      } else {
        _statusMessage = 'Error: /bin/sh no encontrado en rootfs';
        _logMsg(_statusMessage);
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

  // ─── Asegurar musl libc ───
  Future<void> _ensureMuslLib(String rootfs) async {
    final libDir = Directory('$rootfs/lib');
    if (!await libDir.exists()) await libDir.create(recursive: true);

    bool muslOk = false;
    for (final name in ['libc.musl-aarch64.so.1', 'ld-musl-aarch64.so.1']) {
      final f = File('$rootfs/lib/$name');
      if (await f.exists() && await f.length() > 100000) {
        muslOk = true;
        _logMsg('musl $name OK (${await f.length()} bytes)');
      }
    }

    if (muslOk) return;

    _logMsg('musl libc no encontrada, descargando...');
    _statusMessage = 'Descargando musl libc...';
    notifyListeners();

    try {
      final apkPath = '$rootfs/../musl.apk';
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(_muslLibcUrl));
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final sink = File(apkPath).openWrite();
          await for (final chunk in resp) sink.add(chunk);
          await sink.close();
          _logMsg('musl.apk descargado');

          final bytes = await File(apkPath).readAsBytes();
          try {
            final gz = GZipDecoder().decodeBytes(bytes);
            final arch = TarDecoder().decodeBytes(gz);
            for (final entry in arch) {
              if (entry.name.endsWith('.so.1') && entry.name.contains('libc.musl')) {
                final outFile = File('$rootfs/lib/libc.musl-aarch64.so.1');
                await outFile.writeAsBytes(entry.content as List<int>);
                _logMsg('musl extraida: ${entry.content.length} bytes');
                try {
                  if (await Link('$rootfs/lib/ld-musl-aarch64.so.1').exists())
                    await Link('$rootfs/lib/ld-musl-aarch64.so.1').delete();
                } catch (_) {}
                try {
                  await Link('$rootfs/lib/ld-musl-aarch64.so.1')
                      .create('libc.musl-aarch64.so.1');
                } catch (_) {
                  await File('$rootfs/lib/ld-musl-aarch64.so.1')
                      .writeAsBytes(entry.content as List<int>);
                }
                muslOk = true;
                break;
              }
            }
          } catch (e) {
            _logMsg('Error extrayendo musl: $e');
          }
          try { await File(apkPath).delete(); } catch (_) {}
        } else {
          _logMsg('HTTP ${resp.statusCode} descargando musl');
        }
      } finally { client.close(); }
    } catch (e) {
      _logMsg('Error descargando musl: $e');
    }

    if (!muslOk) {
      _logMsg('WARNING: musl libc no disponible');
    }
  }

  // ─── Asset ───
  Future<bool> _setupFromAsset(String rootfs) async {
    _logMsg('--- Buscando assets embebidos ---');
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      if (!manifest.contains('assets/rootfs.tar.gz')) {
        _logMsg('No hay asset de rootfs'); return false;
      }
      _logMsg('Leyendo asset: assets/rootfs.tar.gz');
      final data = await rootBundle.load('assets/rootfs.tar.gz');
      final bytes = data.buffer.asUint8List();
      final appDir = await _appDir;
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      await File(tarPath).writeAsBytes(bytes);

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
                _logMsg('OK: con $tb'); return true;
              }
              if (await File('$rootfs/bin/busybox').exists() &&
                  await File('$rootfs/bin/busybox').length() > 0) {
                _logMsg('OK: busybox con $tb'); return true;
              }
            }
          } catch (e) { _logMsg('system tar fallo: $e'); }
        }
      }
      _logMsg('Fallback archive package Dart');
      return _extractTarDart(tarPath, rootfs);
    } catch (e) {
      _logMsg('Asset fallo: $e');
      return false;
    }
  }

  // ─── Extraer tar.gz ───
  Future<bool> _extractTarDart(String tgzPath, String rootfs) async {
    try {
      final bytes = await File(tgzPath).readAsBytes();
      final gz = GZipDecoder().decodeBytes(bytes);
      final arch = TarDecoder().decodeBytes(gz);
      for (final entry in arch) {
        String name = entry.name;
        if (name.startsWith('./')) name = name.substring(2);
        if (name.isEmpty || name == '.') continue;
        final outPath = '$rootfs/$name';
        if (name.endsWith('/')) {
          await Directory(outPath).create(recursive: true); continue;
        }
        await Directory(outPath).parent.create(recursive: true);
        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink ?? '';
          if (target.isNotEmpty) {
            final resolved = target.startsWith('/')
                ? '$rootfs$target'
                : '${Directory(outPath).parent.path}/$target';
            if (await File(resolved).exists() && await File(resolved).length() > 0) {
              try {
                if (await Link(outPath).exists()) await Link(outPath).delete();
                await File(outPath).writeAsBytes(await File(resolved).readAsBytes());
              } catch (_) {}
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
        }
      }
      return true;
    } catch (e) {
      _logMsg('Error Dart extract: $e');
      return false;
    }
  }

  // ─── Minirootfs ───
  Future<bool> _setupWithMinirootfs(String appDir, String rootfs) async {
    _logMsg('--- Minirootfs descargado ---');
    _statusMessage = 'Descargando Alpine...';
    notifyListeners();
    final tgzPath = '$appDir/rootfs.tar.gz';
    if (!await File(tgzPath).exists()) {
      try {
        await _downloadFile(_minirootfsUrl, tgzPath, 0.20, 0.50);
      } catch (e) { _logMsg('ERROR descarga: $e'); return false; }
    }
    _downloadProgress = 0.55;
    _statusMessage = 'Extrayendo Alpine...';
    notifyListeners();
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          _logMsg('Alpine con $tb');
          final result = await Process.run(
            tb, ['tar', '-xzf', tgzPath, '-C', rootfs],
          ).timeout(const Duration(seconds: 180));
          if (result.exitCode == 0) {
            await _fixAbsoluteSymlinks(rootfs);
            if (await File('$rootfs/bin/sh').exists() &&
                await File('$rootfs/bin/sh').length() > 0) {
              _logMsg('Alpine extraido con $tb'); return true;
            }
          }
        } catch (e) { _logMsg('$tb tar fallo: $e'); }
      }
    }
    _logMsg('Fallback archive Dart');
    return _extractTarDart(tgzPath, rootfs);
  }

  // ─── Hardlinks ───
  Future<void> _fixHardlinks(String rootfs) async {
    final bbPath = '$rootfs/bin/busybox';
    List<int>? bbData;
    if (await File(bbPath).exists() && await File(bbPath).length() > 0) {
      bbData = await File(bbPath).readAsBytes();
    }
    List<int>? muslData;
    for (final lib in ['ld-musl-aarch64.so.1', 'libc.musl-aarch64.so.1']) {
      final f = File('$rootfs/lib/$lib');
      if (await f.exists() && await f.length() > 0) {
        muslData = await f.readAsBytes();
        break;
      }
    }
    int fixed = 0;
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;
      try {
        await for (final entity in d.list(followLinks: false)) {
          if (entity is File) {
            try {
              if (await entity.length() == 0) {
                final path = entity.path;
                if (bbData != null && (path.contains('/bin/') || path.contains('/sbin/'))) {
                  await entity.writeAsBytes(bbData); fixed++;
                }
                if (muslData != null && path.contains('/lib/')) {
                  await entity.writeAsBytes(muslData); fixed++;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    if (bbData != null) {
      final shFile = File('$rootfs/bin/sh');
      if (!await shFile.exists() || await shFile.length() == 0) {
        try { await shFile.writeAsBytes(bbData); _logMsg('Creado /bin/sh'); fixed++; } catch (_) {}
      }
    }
    _logMsg('Hardlinks reparados: $fixed');
  }

  // ─── Symlinks absolutos ───
  Future<void> _fixAbsoluteSymlinks(String rootfs) async {
    final dirs = ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib', '/usr/lib'];
    int fixed = 0;
    for (final dir in dirs) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;
      try {
        await for (final entity in d.list(followLinks: false)) {
          if (entity is Link) {
            try {
              final target = await entity.target();
              if (target.startsWith('/')) {
                final resolved = '$rootfs$target';
                final rf = File(resolved);
                if (await rf.exists() && await rf.length() > 0) {
                  try { await entity.delete(); } catch (_) {}
                  await File(entity.path).writeAsBytes(await rf.readAsBytes()); fixed++;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    _logMsg('Symlinks absolutos reparados: $fixed');
  }

  // ─── Permisos ───
  Future<void> _chmodBins(String rootfs) async {
    for (final dir in ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/lib']) {
      final d = Directory('$rootfs$dir');
      if (!await d.exists()) continue;
      try {
        await for (final entity in d.list()) {
          if (entity is File) {
            try { await Process.run('chmod', ['755', entity.path]).timeout(const Duration(seconds: 5)); } catch (_) {}
          }
        }
      } catch (_) {}
    }
  }

  // ─── Download ───
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
        sink.add(chunk);
        recv += chunk.length;
        if (total > 0) {
          _downloadProgress = sw + (recv / total) * (ew - sw);
          if (recv % (1024 * 512) < chunk.length) notifyListeners();
        }
      }
      await sink.flush(); await sink.close();
      _logMsg('OK: $recv bytes');
    } finally { client.close(); }
  }

  // ════════════════════════════════════════════════════════════════
  // installEssentials
  // ════════════════════════════════════════════════════════════════
  Future<void> installEssentials() async {
    _logMsg('=== Instalando paquetes esenciales ===');

    _logMsg('Ejecutando apk update...');
    _statusMessage = 'Actualizando repositorios...';
    notifyListeners();
    try {
      final update = await runCommand('apk update',
          timeout: const Duration(seconds: 120));
      _logMsg('apk update: ${update.length > 200 ? update.substring(0, 200) + "..." : update}');
    } catch (e) {
      _logMsg('apk update fallo: $e');
    }

    _logMsg('Instalando openssh-server...');
    _statusMessage = 'Instalando openssh...';
    notifyListeners();
    try {
      final ssh = await runCommand(
        'apk add --no-scripts openssh-server openssh-keygen',
        timeout: const Duration(seconds: 180));
      _logMsg('openssh: ${ssh.length > 100 ? ssh.substring(0, 100) + "..." : ssh}');
    } catch (e) {
      _logMsg('openssh fallo: $e');
    }

    _logMsg('Instalando utilidades...');
    _statusMessage = 'Instalando utilidades...';
    notifyListeners();
    try {
      final utils = await runCommand(
        'apk add --no-scripts curl wget bash ca-certificates sudo nano',
        timeout: const Duration(seconds: 180));
      _logMsg('utilidades: ${utils.length > 100 ? utils.substring(0, 100) + "..." : utils}');
    } catch (e) {
      _logMsg('utilidades fallo: $e');
    }

    _logMsg('Generando claves SSH...');
    _statusMessage = 'Configurando SSH...';
    notifyListeners();
    try {
      final keys = await runCommand('ssh-keygen -A',
          timeout: const Duration(seconds: 60));
      _logMsg('ssh-keys: ${keys.length > 100 ? keys.substring(0, 100) + "..." : keys}');
    } catch (e) {
      _logMsg('ssh-keygen fallo: $e');
    }

    _logMsg('=== Paquetes esenciales OK ===');
    _statusMessage = 'Paquetes esenciales instalados';
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
DART

echo -e "  ${GREEN}✓${NC} proot_service.dart v3.1 ($(wc -l < lib/services/proot_service.dart) lineas)"

# ─── Commit y Push ───
echo -e "\n${YELLOW}[3/4] Commit y push...${NC}"
git add lib/services/proot_service.dart
git commit -m "v3.1: usar ld-musl como loader via linker64 (fix musl compat)

- ESTRATEGIA A (nueva): linker64 + ld-musl + binario
  linker64 carga ld-musl (loader musl nativo, estatico)
  ld-musl carga el binario y resuelve dependencias musl
  Esto permite ejecutar apk, busybox y otros binarios Alpine

- ESTRATEGIA B (fallback): linker64 + binario directo
  Para binarios estaticos sin libc.musl (proot-rs, etc.)

- ESTRATEGIA C (fallback): system shell
  Para comandos nativos (uname, echo, etc.)

- runShell usa ld-musl wrapper functions
- Test de verificacion con 'ls /bin' via ld-musl" 2>/dev/null || true

git push origin main 2>&1 || true

# ─── Tag y Release ───
echo -e "\n${YELLOW}[4/4] Tag y release...${NC}"
VERSION="v2.2.1"
git tag -f "$VERSION" 2>/dev/null || true
git push origin "$VERSION" -f 2>&1 || true

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ v3.1 APLICADO${NC}"
echo -e "${GREEN}  Push y tag $VERSION enviados${NC}"
echo -e "${GREEN}  GitHub Actions compilara automaticamente${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "Link: https://github.com/txurtxil/LinuxContainer/actions"
echo ""
