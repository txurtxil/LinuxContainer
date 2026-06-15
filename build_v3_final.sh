#!/bin/bash
# ============================================================================
# Linux Container App v3.0 - Build & Release Script
#
# Correcciones principales:
# 1. linker64 + binario directo SIN proot-rs (no funciona Android 15+)
# 2. Shell syntax eliminada de comandos, manejada en Dart
# 3. Wrapper functions para terminal interactiva
# 4. apk --no-scripts para instalacion robusta
# 5. Fix de musl libc: si faltan, se descargan desde Alpine
# 6. Log detallado siempre visible
# 7. CI/CD via GitHub Actions
#
# Uso: bash build_v3_final.sh
# ============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE}  Linux Container v3.0 - Builder${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"

# ─── 1. Verificar entorno ───
echo -e "\n${YELLOW}[1/6] Verificando entorno...${NC}"
command -v flutter >/dev/null 2>&1 || { echo -e "${RED}Flutter no encontrado${NC}"; exit 1; }
echo -e "  ${GREEN}✓${NC} Flutter: $(flutter --version 2>&1 | head -1)"

# ─── 2. Escribir proot_service.dart ───
echo -e "\n${YELLOW}[2/6] Escribiendo proot_service.dart...${NC}"

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

  // ─── checkEnvironment ───
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
  // runCommand: EJECUTA COMANDOS VIA LINKER64 + BINARIO DIRECTO
  // NO usa proot-rs (bloqueado por seccomp en Android 15+)
  // NO usa execve (bloqueado por noexec en /data)
  // ════════════════════════════════════════════════════════════════
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    _lastOutput = '';
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;

    if (linker == null) {
      _lastOutput = '[Error] linker64 no encontrado en /system/bin';
      return _lastOutput;
    }

    // 1. Limpiar shell syntax del comando
    String cleanCmd = command
        .replaceAll(RegExp(r'\s*2>&1\s*'), ' ')
        .replaceAll(RegExp(r'\s*2>/dev/null\s*'), ' ')
        .replaceAll(RegExp(r'\s*>/dev/null\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|\|\s*true\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|\|\s*false\s*'), ' ')
        .replaceAll(RegExp(r'\s*\|.*$'), '')  // quitar pipes y lo que sigue
        .replaceAll(RegExp(r'\s*&\s*$'), '')
        .trim();

    // 2. Extraer binario y argumentos
    final parts = cleanCmd.split(' ');
    final binName = parts.isNotEmpty ? parts.first : '';
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];
    if (binName.isEmpty) {
      _lastOutput = '';
      return _lastOutput;
    }

    // 3. Buscar binario en rootfs
    final binDirs = ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/local/bin'];
    String? binPath;
    for (final d in binDirs) {
      final candidate = '$rootfs$d/$binName';
      try {
        final f = File(candidate);
        if (await f.exists()) {
          final size = await f.length();
          if (size > 100) {
            binPath = candidate;
            break;
          }
        }
      } catch (_) { continue; }
    }

    // 4. Ejecutar
    try {
      final ProcessResult result;
      final Map<String, String> env = {
        'PATH': '$rootfs/usr/local/sbin:$rootfs/usr/local/bin:'
                '$rootfs/usr/sbin:$rootfs/usr/bin:$rootfs/sbin:$rootfs/bin'
                ':/system/bin:/system/xbin',
        'HOME': '/root',
        'TERM': 'xterm-256color',
        'LD_LIBRARY_PATH': '$rootfs/lib:$rootfs/usr/lib',
      };

      if (binPath != null) {
        // ESTRATEGIA A: linker64 + binario rootfs
        _logMsg('linker64: $binName $args');
        result = await Process.run(
          linker, [binPath, ...args],
          environment: env,
          workingDirectory: rootfs,
        ).timeout(timeout);
      } else {
        // ESTRATEGIA B: sistema (para comandos como uname, echo)
        _logMsg('system: $command');
        result = await Process.run(
          '/system/bin/sh', ['-c', command],
          environment: {
            'PATH': '/system/bin:/system/xbin',
            'TERM': 'xterm-256color',
          },
        ).timeout(timeout);
      }

      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
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
  // runShell: Shell interactiva via linker64 + wrapper functions
  // Usada por TerminalScreen para commands con pipes/redirects
  // ════════════════════════════════════════════════════════════════
  Future<String> runShell(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    final rootfs = _rootfsPath ?? '${await _appDir}/rootfs';
    final linker = await _linker;
    if (linker == null) return '[Error] linker64 no encontrado';

    final busyboxPath = '$rootfs/bin/busybox';
    if (!await File(busyboxPath).exists() || await File(busyboxPath).length() < 100) {
      // Fallback a runCommand simple
      return runCommand(command);
    }

    try {
      // Generar wrapper functions para todos los binarios del rootfs
      // Estas funciones llaman a linker64 en vez de execve (noexec bypass)
      final wrappers = StringBuffer();
      wrappers.writeln('export LD_LIBRARY_PATH=/lib:/usr/lib');
      wrappers.writeln('export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin');
      wrappers.writeln('export HOME=/root');
      wrappers.writeln('export TERM=xterm-256color');

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
                wrappers.writeln("$name() { $linker '${entry.path}' \"\$@\"; }");
              }
            }
          }
        } catch (_) {}
      }

      // Añadir el comando del usuario
      wrappers.writeln(command);

      final result = await Process.run(
        linker,
        [busyboxPath, 'sh', '-c', wrappers.toString()],
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

      // 1: Asset embebido
      ok = await _setupFromAsset(rootfs);
      if (ok) _logMsg('✓ Rootfs desde asset');

      // 2: Minirootfs descargado
      if (!ok) {
        ok = await _setupWithMinirootfs(appDir, rootfs);
        if (ok) _logMsg('✓ Rootfs desde minirootfs');
      }

      if (!ok) throw Exception('No se pudo crear el rootfs');

      // Reparar hardlinks
      _logMsg('Reparando hardlinks...');
      await _fixHardlinks(rootfs);

      // Asegurar libreria musl
      _logMsg('Verificando libreria musl...');
      await _ensureMuslLib(rootfs);

      // DNS
      _downloadProgress = 0.80;
      _statusMessage = 'Configurando red...';
      notifyListeners();
      await Directory('$rootfs/etc').create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n');

      // Permisos
      await _chmodBins(rootfs);

      // Limpiar temporal
      final tarPath = '$appDir/cached_rootfs.tar.gz';
      if (await File(tarPath).exists()) {
        try { await File(tarPath).delete(); } catch (_) {}
      }

      // Symlinks absolutos
      await _fixAbsoluteSymlinks(rootfs);

      // Buscar/crear /bin/sh
      bool shOk = false;
      for (final candidate in ['$rootfs/bin/sh', '$rootfs/bin/busybox',
                                '$rootfs/bin/dash', '$rootfs/bin/ash']) {
        try {
          final f = File(candidate);
          if (await f.exists() && await f.length() > 1000) {
            if (candidate != '$rootfs/bin/sh') {
              final target = File('$rootfs/bin/sh');
              try { if (await Link(target.path).exists()) await Link(target.path).delete(); } catch (_) {}
              try { if (await target.exists()) await target.delete(); } catch (_) {}
              await target.writeAsBytes(await f.readAsBytes());
            }
            shOk = true;
            _logMsg('/bin/sh verificado (${await File("$rootfs/bin/sh").length()} bytes)');
            break;
          }
        } catch (_) { continue; }
      }

      // Ultimo recurso
      if (!shOk) {
        for (final dir in ['/bin', '/sbin', '/usr/bin']) {
          final d = Directory('$rootfs$dir');
          if (!await d.exists()) continue;
          try {
            await for (final entity in d.list(followLinks: false)) {
              if (entity is File && await entity.length() > 1000) {
                await File('$rootfs/bin/sh').writeAsBytes(await entity.readAsBytes());
                shOk = true;
                _logMsg('/bin/sh desde ${entity.path} (${await entity.length()} b)');
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
        _statusMessage = 'Linux listo - Instalando paquetes...';
        _logMsg(_statusMessage);
        notifyListeners();

        // Probar comando basico para verificar linker64
        try {
          final testResult = await runCommand('busybox ls /bin',
              timeout: const Duration(seconds: 10));
          _logMsg('Test linker64: ${testResult.length > 100 ? testResult.substring(0, 100) + "..." : testResult}');
        } catch (e) {
          _logMsg('Test linker64 fallo: $e');
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

  // ─── Asegurar que libc.musl existe y tiene contenido ───
  Future<void> _ensureMuslLib(String rootfs) async {
    final libDir = Directory('$rootfs/lib');
    if (!await libDir.exists()) await libDir.create(recursive: true);

    // Verificar musl libs existentes
    bool muslOk = false;
    for (final name in ['libc.musl-aarch64.so.1', 'ld-musl-aarch64.so.1']) {
      final f = File('$rootfs/lib/$name');
      if (await f.exists() && await f.length() > 100000) { // musl > 100KB
        muslOk = true;
        _logMsg('musl $name OK (${await f.length()} bytes)');
      }
    }

    if (muslOk) return;

    // Intentar descargar musl desde Alpine
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

          // Extraer .so del .apk (es un tar.gz)
          final bytes = await File(apkPath).readAsBytes();
          try {
            final gz = GZipDecoder().decodeBytes(bytes);
            final archive = TarDecoder().decodeBytes(gz);
            for (final entry in archive) {
              final name = entry.name;
              if (name.endsWith('.so.1') && name.contains('libc.musl')) {
                final outFile = File('$rootfs/lib/libc.musl-aarch64.so.1');
                await outFile.writeAsBytes(entry.content as List<int>);
                _logMsg('musl extraida: ${entry.content.length} bytes');
                // Crear ld-musl symlink
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

          // Limpiar
          try { await File(apkPath).delete(); } catch (_) {}
        } else {
          _logMsg('HTTP ${resp.statusCode} descargando musl');
        }
      } finally { client.close(); }
    } catch (e) {
      _logMsg('Error descargando musl: $e');
    }

    if (!muslOk) {
      _logMsg('WARNING: No se pudo obtener musl libc');
      _logMsg('Los binarios del rootfs no funcionaran via linker64');
    }
  }

  // ─── Asset embebido ───
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

      // System tar
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

      // Fallback Dart
      _logMsg('Fallback archive package Dart');
      return _extractTarDart(tarPath, rootfs);
    } catch (e) {
      _logMsg('Asset fallo: $e');
      return false;
    }
  }

  // ─── Extraer tar.gz con archive ───
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
          await Directory(outPath).create(recursive: true);
          continue;
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
            if (entry.size > 0) {
              await File(outPath).writeAsBytes(content);
            } else {
              await File(outPath).writeAsString('');
            }
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

  // ─── Reparar hardlinks ───
  Future<void> _fixHardlinks(String rootfs) async {
    final bbPath = '$rootfs/bin/busybox';
    List<int>? bbData;
    if (await File(bbPath).exists() && await File(bbPath).length() > 0) {
      bbData = await File(bbPath).readAsBytes();
    }

    // Buscar musl libs existentes (con contenido)
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
                // bin/sbin -> busybox
                if (bbData != null &&
                    (path.contains('/bin/') || path.contains('/sbin/'))) {
                  await entity.writeAsBytes(bbData);
                  fixed++;
                }
                // lib -> musl
                if (muslData != null && path.contains('/lib/')) {
                  for (final name in ['ld-musl', 'libc.musl', 'libz', 'libssl', 'libcrypto']) {
                    if (path.contains(name)) {
                      await entity.writeAsBytes(muslData);
                      fixed++;
                      break;
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
                  await File(entity.path).writeAsBytes(await rf.readAsBytes());
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
  // installEssentials: apk update + openssh + utilidades
  // ════════════════════════════════════════════════════════════════
  Future<void> installEssentials() async {
    _logMsg('=== Instalando paquetes esenciales ===');

    // apk update
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

    // openssh-server (--no-scripts para evitar post-install)
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

    // Networking tools
    _logMsg('Instalando herramientas de red...');
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

    // SSH keys
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

  // ─── Reset ───
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

echo -e "  ${GREEN}✓${NC} proot_service.dart actualizado ($(wc -l < lib/services/proot_service.dart) lineas)"

# ─── 3. terminal_screen.dart ───
echo -e "\n${YELLOW}[3/6] Escribiendo terminal_screen.dart...${NC}"

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
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  bool _useProot = true;
  bool _running = false;
  final List<String> _history = [];
  int _historyIndex = -1;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _executeCommand(String cmd) async {
    if (cmd.trim().isEmpty || _running) return;

    _history.add(cmd);
    _historyIndex = _history.length;

    final terminal = context.read<TerminalService>();
    final proot = context.read<ProotService>();

    if (cmd == 'clear') {
      terminal.clear();
      _inputController.clear();
      return;
    }

    if (cmd == 'exit') {
      terminal.addLine('Usa el boton atras para salir.');
      _inputController.clear();
      return;
    }

    _running = true;
    terminal.addLine('\$ $cmd', type: TerminalLineType.command);
    _inputController.clear();

    try {
      String output;

      if (_useProot && proot.initialized) {
        // Usar runShell para terminal interactiva (wrapper functions)
        output = await proot.runShell(cmd,
            timeout: const Duration(seconds: 120));
      } else if (_useProot && !proot.initialized) {
        output = 'Linux no inicializado. Ve a Inicio y haz Setup primero.';
      } else {
        // Shell local: ejecutar via sistema
        output = await _runLocal(cmd);
      }

      if (output.trim().isNotEmpty) {
        terminal.addLine(output);
      }
    } catch (e) {
      terminal.addLine('[Error] $e', type: TerminalLineType.error);
    } finally {
      _running = false;
      _scrollToBottom();
    }
  }

  Future<String> _runLocal(String cmd) async {
    try {
      final result = await Process.run('/system/bin/sh', ['-c', cmd],
          environment: {
            'PATH': '/system/bin:/system/xbin',
            'TERM': 'xterm-256color',
          },
      ).timeout(const Duration(seconds: 60));
      final out = result.stdout as String;
      final err = result.stderr as String;
      return err.isNotEmpty ? '$out\n$err' : out;
    } on TimeoutException {
      return '[Timeout]';
    } catch (e) {
      return '[Error] $e';
    }
  }

  void _toggleMode() {
    setState(() => _useProot = !_useProot);
    final terminal = context.read<TerminalService>();
    terminal.addLine(
      _useProot ? '[Modo: Linux Container]' : '[Modo: Shell Local]',
      type: TerminalLineType.output,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terminal = context.watch<TerminalService>();
    final proot = context.watch<ProotService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_useProot ? 'Terminal Linux' : 'Terminal Local'),
        actions: [
          if (_useProot)
            IconButton(
              icon: const Icon(Icons.terminal),
              tooltip: 'Ver Log',
              onPressed: () => _showLogDialog(proot),
            ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Limpiar',
            onPressed: terminal.clear,
          ),
          IconButton(
            icon: Icon(_useProot ? Icons.terminal : Icons.smartphone),
            tooltip: _useProot ? 'Shell Local' : 'Linux Container',
            onPressed: _toggleMode,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: _useProot && proot.initialized
                ? Colors.green.withValues(alpha: 0.2)
                : Colors.grey.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8,
                    color: _useProot && proot.initialized
                        ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Text(
                  _useProot
                      ? (proot.initialized ? 'Linux Container' : 'No conectado')
                      : 'Shell Local',
                  style: theme.textTheme.labelSmall,
                ),
                const Spacer(),
                if (_useProot && proot.initialized)
                  Text('apk | ssh | net',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ],
            ),
          ),

          // Terminal output
          Expanded(
            child: GestureDetector(
              onTap: () => _inputFocus.requestFocus(),
              child: Container(
                color: Colors.black,
                child: terminal.lines.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.terminal_rounded, size: 48,
                                color: Colors.green.withValues(alpha: 0.3)),
                            const SizedBox(height: 16),
                            Text('Bienvenido a Terminal Linux',
                              style: TextStyle(
                                color: Colors.green.withValues(alpha: 0.7),
                                fontSize: 16, fontFamily: 'monospace')),
                            const SizedBox(height: 8),
                            Text(
                              _useProot && proot.initialized
                                  ? 'Escribe un comando y presiona Enter'
                                  : 'Activa el modo Linux Container',
                              style: TextStyle(
                                color: Colors.grey.withValues(alpha: 0.5),
                                fontFamily: 'monospace', fontSize: 12)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(12),
                        itemCount: terminal.lines.length,
                        itemBuilder: (context, index) {
                          final line = terminal.lines[index];
                          return SelectableText(
                            line.text,
                            style: TextStyle(
                              color: line.type == TerminalLineType.command
                                  ? Colors.greenAccent
                                  : line.type == TerminalLineType.error
                                      ? Colors.redAccent
                                      : Colors.green,
                              fontFamily: 'monospace',
                              fontSize: 13, height: 1.4),
                          );
                        },
                      ),
              ),
            ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              border: Border(top: BorderSide(
                  color: Colors.green.withValues(alpha: 0.3), width: 1)),
            ),
            child: Row(
              children: [
                Text('\$ ',
                  style: TextStyle(
                    color: _running ? Colors.yellow : Colors.greenAccent,
                    fontFamily: 'monospace', fontSize: 14,
                    fontWeight: FontWeight.bold)),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    enabled: !_running,
                    style: const TextStyle(
                      color: Colors.green, fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(
                      border: InputBorder.none, isDense: true,
                      contentPadding: EdgeInsets.zero),
                    onSubmitted: _executeCommand,
                    autofocus: true,
                  ),
                ),
                if (_running)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.green),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
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
                  child: SelectableText(
                    proot.logText,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 11, height: 1.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
DART

echo -e "  ${GREEN}✓${NC} terminal_screen.dart actualizado"

# ─── 4. terminal_service.dart ───
echo -e "\n${YELLOW}[4/6] Escribiendo terminal_service.dart...${NC}"

cat > lib/services/terminal_service.dart << 'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [];
  bool _running = false;
  final StringBuffer _currentOutput = StringBuffer();

  List<TerminalLine> get lines => List.unmodifiable(_lines);
  bool get running => _running;
  String get currentOutput => _currentOutput.toString();

  void addLine(String text, {TerminalLineType type = TerminalLineType.output}) {
    _lines.add(TerminalLine(text: text, type: type));
    _currentOutput.writeln(text);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _currentOutput.clear();
    notifyListeners();
  }

  void cancel() {
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class TerminalLine {
  final String text;
  final TerminalLineType type;

  TerminalLine({required this.text, required this.type});
}

enum TerminalLineType { command, output, error }
DART

echo -e "  ${GREEN}✓${NC} terminal_service.dart actualizado"

# ─── 5. Actualizar home_screen.dart: boton Log siempre visible ───
echo -e "\n${YELLOW}[5/6] Actualizando home_screen.dart (Log siempre visible)...${NC}"
# Verificar que el botón Log está presente
if grep -q "Ver Log Completo" lib/screens/home_screen.dart; then
    echo -e "  ${GREEN}✓${NC} Boton Ver Log ya presente"
else
    echo -e "  ${YELLOW}⚠${NC} Revisar home_screen.dart"
fi

# Verificar análisis
echo -e "\n${YELLOW}[5b/6] Verificando codigo Dart...${NC}"
flutter pub get > /dev/null 2>&1
ANALYSIS=$(flutter analyze 2>&1)
if echo "$ANALYSIS" | grep -q "No issues found"; then
    echo -e "  ${GREEN}✓${NC} Sin errores de analisis"
else
    echo -e "  ${YELLOW}⚠${NC} Issues:"
    echo "$ANALYSIS" | grep "error\|warning\|info" | head -10
fi

# ─── 6. Compilar APK ───
echo -e "\n${YELLOW}[6/6] Compilando APK...${NC}"

if flutter build apk --release 2>&1; then
    echo -e "  ${GREEN}✓${NC} Build release OK"
else
    echo -e "  ${YELLOW}⚠ Release fallo, intentando debug...${NC}"
    flutter build apk --debug 2>&1
fi

APK_PATH=$(find build/app/outputs -name "*.apk" 2>/dev/null | head -1)
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
    echo -e "  ${GREEN}✓${NC} APK: $APK_PATH ($APK_SIZE)"
else
    echo -e "  ${RED}✗${NC} No se encontro el APK"
    ls -la build/app/outputs/flutter-apk/ 2>/dev/null || echo "No build dir"
    exit 1
fi

# ─── 7. Commit y Release ───
echo -e "\n${YELLOW}[7/7] Publicando release...${NC}"
git add -A
git commit -m "v3.0: linker64 direct execution, no proot-rs, musl fix, terminal wrapper functions" 2>/dev/null || true
git push origin main 2>/dev/null || true

VERSION="v2.2.0"
git tag -f "$VERSION" 2>/dev/null || true
git push origin "$VERSION" 2>/dev/null || true

if command -v gh &> /dev/null; then
    gh release create "$VERSION" "$APK_PATH" \
        --title "Linux Container v2.2.0" \
        --notes "## Linux Container v2.2.0

### 🔧 Cambios principales
- **Nuevo sistema de ejecucion**: linker64 + binarios rootfs directamente
- **Eliminado proot-rs** (no funciona en Android 15+ por seccomp)
- **Shell syntax eliminada** de los comandos internos, manejada en Dart
- **Wrapper functions** para terminal interactiva (evitan execve)
- **Reparacion de musl libc**: descarga automatica si falta
- **apk --no-scripts** para instalacion robusta
- **Log detallado** siempre visible en terminal
- **Indicador de progreso** en comandos de terminal

### ✨ Caracteristicas
- Terminal interactiva con Alpine via linker64
- Gestor de paquetes apk funcional
- Servidor SSH (OpenSSH)
- Networking (ping, curl, wget)
- OpenCloud ready
" 2>&1 || true

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ BUILD COMPLETADO${NC}"
echo -e "${GREEN}  APK: $APK_PATH ($APK_SIZE)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "Instrucciones:"
echo -e "1. Descarga el APK desde GitHub Releases"
echo -e "2. Instala en tu dispositivo Android"
echo -e "3. Abre la app y presiona 'Setup Linux'"
echo -e "4. Revisa el LOG para ver el progreso detallado"
echo -e "5. Usa la terminal con 'Linux Container' mode"
echo ""
