import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

class ProotService extends ChangeNotifier {
  String? _rootfsPath;
  bool _initialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusMessage = 'No iniciado';
  String _lastOutput = '';

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String get lastOutput => _lastOutput;

  Future<String> get _appDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container';
  }

  Future<bool> checkEnvironment() async {
    try {
      final rootfs = '${await _appDir}/rootfs';
      _rootfsPath = rootfs;
      if (await Directory(rootfs).exists()) {
        if (await File('$rootfs/bin/sh').exists()) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Rootfs no encontrado - pulsa Setup';
      notifyListeners();
      return false;
    } catch (e) {
      _statusMessage = 'Error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> setupEnvironment() async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _statusMessage = 'Iniciando descarga...';
    _lastOutput = '';
    notifyListeners();

    try {
      final appDir = await _appDir;
      final rootfs = '$appDir/rootfs';
      _rootfsPath = rootfs;

      // Crear directorios
      await Directory(appDir).create(recursive: true);
      await Directory(rootfs).create(recursive: true);
      await Directory('$rootfs/proc').create(recursive: true);
      await Directory('$rootfs/sys').create(recursive: true);
      await Directory('$rootfs/tmp').create(recursive: true);

      _downloadProgress = 0.05;
      _statusMessage = 'Descargando Alpine Linux minimal...';
      notifyListeners();

      // Descargar Alpine minirootfs (ARM64)
      final tarGzFile = File('$appDir/rootfs.tar.gz');

      if (!await tarGzFile.exists()) {
        await _downloadFile(
          'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz',
          tarGzFile.path,
        );
      }

      _downloadProgress = 0.5;
      _statusMessage = 'Extrayendo rootfs...';
      notifyListeners();

      // Extraer usando Dart puro (no necesita tar externo)
      if (!await File('$rootfs/bin/sh').exists()) {
        await _extractTarGz(tarGzFile.path, rootfs);
      }

      _downloadProgress = 0.85;
      _statusMessage = 'Configurando entorno...';
      notifyListeners();

      // DNS
      final resolvDir = Directory('$rootfs/etc');
      await resolvDir.create(recursive: true);
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
      );

      // hosts
      await File('$rootfs/etc/hosts').writeAsString(
        '127.0.0.1 localhost\n::1 localhost\n',
      );

      _downloadProgress = 1.0;
      _initialized = true;
      _statusMessage = 'Alpine Linux listo';

      // Verificar que sh existe
      final hasSh = await File('$rootfs/bin/sh').exists();
      if (!hasSh) {
        _statusMessage = 'Error: /bin/sh no encontrado en rootfs';
        _initialized = false;
      }
    } catch (e) {
      _statusMessage = 'Error: $e';
      _lastOutput = '$_lastOutput\nError: $e';
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> _extractTarGz(String tarPath, String destPath) async {
    final bytes = await File(tarPath).readAsBytes();
    _statusMessage = 'Descomprimiendo gzip...';
    notifyListeners();

    // Descomprimir gzip
    final gzipBytes = GZipDecoder().decodeBytes(bytes);

    _statusMessage = 'Extrayendo archivos...';
    notifyListeners();

    // Decodificar tar
    final archive = TarDecoder().decodeBytes(gzipBytes);
    int extracted = 0;
    final total = archive.length;

    for (final file in archive) {
      final outPath = '$destPath/${file.name}';

      if (file.isFile) {
        // Crear directorio padre
        await Directory(outPath).parent.create(recursive: true);
        await File(outPath).writeAsBytes(file.content as List<int>);
        // Preservar permisos de ejecución
        if (file.name.startsWith('bin/') || file.name.startsWith('usr/bin/') ||
            file.name.startsWith('sbin/') || file.name.startsWith('lib/')) {
          await Process.run('chmod', ['+x', outPath]);
        }
      } else if (file.isSymbolicLink) {
        final target = file.symbolicLink ?? '';
        await Directory(outPath).parent.create(recursive: true);
        if (await File(outPath).exists() || await Link(outPath).exists()) {
          try { await File(outPath).delete(); } catch (_) {}
          try { await Link(outPath).delete(); } catch (_) {}
        }
        await Link(outPath).create(target);
      }

      extracted++;
      if (extracted % 500 == 0) {
        _statusMessage = 'Extrayendo $extracted/$total archivos...';
        notifyListeners();
      }
    }
  }

  Future<void> _downloadFile(String url, String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final totalBytes = response.contentLength;
      int receivedBytes = 0;

      final sink = File(path).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = 0.05 + (receivedBytes / totalBytes) * 0.45;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
  }

  /// Ejecuta un comando usando el bin/sh del rootfs
  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 30)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado.\n';
    }

    final shPath = '$_rootfsPath/bin/sh';
    final shExists = await File(shPath).exists();
    if (!shExists) {
      return 'Error: /bin/sh no encontrado en rootfs.\n';
    }

    try {
      final result = await Process.run(
        shPath,
        ['-c', command],
        environment: {
          'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
          'HOME': '/root',
          'TERM': 'xterm-256color',
          'LD_LIBRARY_PATH': '/lib:/usr/lib:/usr/local/lib',
          'PREFIX': _rootfsPath!,
        },
        workingDirectory: _rootfsPath,
        runInShell: false,
      ).timeout(timeout);

      final out = result.stdout as String;
      final err = result.stderr as String;
      _lastOutput = err.isNotEmpty ? '$out\n$err' : out;
      return _lastOutput;
    } on TimeoutException {
      return '\n[Timeout] El comando excedió ${timeout.inSeconds}s\n';
    } catch (e) {
      return '\n[Error] $e\n';
    }
  }

}
