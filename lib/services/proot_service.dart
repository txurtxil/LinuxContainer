import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ProotService extends ChangeNotifier {
  String? _rootfsPath;
  bool _initialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusMessage = 'No iniciado';
  final bool _useDebian = true;

  bool get initialized => _initialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String? get rootfsPath => _rootfsPath;
  bool get useDebian => _useDebian;

  Future<String> get _rootfsDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/linux_container/rootfs';
  }

  Future<String> get _tarPath async {
    final dir = await getApplicationDocumentsDirectory();
    await Directory('${dir.path}/linux_container').create(recursive: true);
    return '${dir.path}/linux_container/rootfs.tar.xz';
  }

  Future<bool> checkEnvironment() async {
    try {
      final rootfs = await _rootfsDir;
      _rootfsPath = rootfs;
      if (await Directory(rootfs).exists()) {
        if (await File('$rootfs/bin/bash').exists() || await File('$rootfs/bin/sh').exists()) {
          _initialized = true;
          _statusMessage = 'Linux listo';
          notifyListeners();
          return true;
        }
      }
      _statusMessage = 'Rootfs no encontrado - haz Setup';
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
    notifyListeners();

    try {
      final rootfs = await _rootfsDir;
      _rootfsPath = rootfs;
      await Directory(rootfs).create(recursive: true);

      _downloadProgress = 0.05;
      _statusMessage = 'Descargando Debian Bookworm (ARM64)...';
      notifyListeners();

      // Debian Bookworm rootfs for ARM64
      // Using debootstrap approach or prebuilt rootfs
      final tarPath = await _tarPath;
      if (!await File(tarPath).exists()) {
        // Try to download a prebuilt Debian rootfs
        final urls = [
          'https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-arm64v8/bookworm/rootfs.tar.xz',
          'https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-arm64v8/stable/rootfs.tar.xz',
        ];

        bool downloaded = false;
        for (final url in urls) {
          try {
            await _downloadFile(url, tarPath);
            downloaded = true;
            break;
          } catch (_) {
            continue;
          }
        }

        if (!downloaded) {
          // Fallback: Create minimal rootfs with debootstrap
          _statusMessage = 'Creando rootfs con debootstrap...';
          notifyListeners();
          final result = await Process.run('debootstrap', [
            '--arch=arm64', '--include=ca-certificates,curl,wget,openssh-server,ping',
            'bookworm', rootfs, 'http://deb.debian.org/debian',
          ], runInShell: false).timeout(const Duration(seconds: 300));
          if (result.exitCode != 0) {
            // Try qemu-debootstrap or manual approach
            await _createMinimalRootfs(rootfs);
          }
          _downloadProgress = 0.9;
        } else {
          _downloadProgress = 0.5;
          _statusMessage = 'Extrayendo rootfs...';
          notifyListeners();

          if (!await File('$rootfs/bin/bash').exists()) {
            final result = await Process.run(
              'tar', ['-xJf', tarPath, '-C', rootfs, '--no-same-owner'],
            );
            if (result.exitCode != 0) {
              // Try gz format
              final result2 = await Process.run(
                'tar', ['-xzf', tarPath, '-C', rootfs, '--no-same-owner'],
              );
              if (result2.exitCode != 0) {
                throw Exception('Error extrayendo rootfs');
              }
            }
          }
          _downloadProgress = 0.8;
        }
      } else {
        _downloadProgress = 0.5;
        _statusMessage = 'Usando rootfs en caché';
        notifyListeners();
      }

      // Extract if tar exists but rootfs not ready
      if (await File(tarPath).exists() && !await File('$rootfs/bin/bash').exists()) {
        _statusMessage = 'Extrayendo rootfs del caché...';
        notifyListeners();
        final result = await Process.run(
          'tar', ['-xJf', tarPath, '-C', rootfs, '--no-same-owner'],
        );
        if (result.exitCode != 0) {
          final result2 = await Process.run(
            'tar', ['-xzf', tarPath, '-C', rootfs, '--no-same-owner'],
          );
          if (result2.exitCode != 0) {
            throw Exception('Error extrayendo rootfs');
          }
        }
      }

      _downloadProgress = 0.85;
      _statusMessage = 'Configurando entorno Debian...';
      notifyListeners();

      // Configure DNS
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
      );

      // Set up apt sources
      await File('$rootfs/etc/apt/sources.list').writeAsString(
        'deb http://deb.debian.org/debian bookworm main contrib non-free\n'
        'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free\n'
        'deb http://deb.debian.org/debian bookworm-updates main contrib non-free\n',
      );

      // Create necessary mount points
      for (final dir in ['proc', 'sys', 'dev', 'dev/pts', 'tmp']) {
        await Directory('$rootfs/$dir').create(recursive: true);
      }

      _downloadProgress = 1.0;
      _initialized = true;
      _statusMessage = 'Debian Linux listo';
    } catch (e) {
      _statusMessage = 'Error: $e';
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> _createMinimalRootfs(String rootfs) async {
    // Create minimal directory structure
    for (final dir in ['bin', 'etc', 'lib', 'usr/bin', 'usr/lib', 'var']) {
      await Directory('$rootfs/$dir').create(recursive: true);
    }

    // Write a minimal /bin/sh using busybox
    await Process.run('cp', ['/bin/busybox', '$rootfs/bin/']);

    _statusMessage = 'Usando busybox como fallback';
    notifyListeners();
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

  Future<String> runCommand(String command, {Duration timeout = const Duration(seconds: 30)}) async {
    if (!_initialized || _rootfsPath == null) {
      return 'Error: Linux no inicializado. Ve a Inicio > Setup Linux.\n';
    }
    try {
      final result = await Process.run(
        'chroot',
        [_rootfsPath!, '/bin/bash', '-c', command],
        environment: {
          'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
          'HOME': '/root',
          'TERM': 'xterm-256color',
          'DEBIAN_FRONTEND': 'noninteractive',
        },
        runInShell: false,
      ).timeout(timeout);

      final out = result.stdout as String;
      final err = result.stderr as String;
      if (err.isNotEmpty && out.isEmpty) return err;
      if (err.isNotEmpty) return '$out\n$err';
      return out;
    } on TimeoutException {
      return '\n[Timeout] El comando excedió ${timeout.inSeconds}s\n';
    } catch (e) {
      // Try with /bin/sh as fallback
      try {
        final result = await Process.run(
          'chroot',
          [_rootfsPath!, '/bin/sh', '-c', command],
          environment: {
            'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME': '/root',
            'TERM': 'xterm-256color',
            'DEBIAN_FRONTEND': 'noninteractive',
          },
          runInShell: false,
        ).timeout(timeout);
        return result.stdout as String;
      } catch (e2) {
        return '\n[Error] $e2\n';
      }
    }
  }

  Future<String> runApt(String args) async {
    if (!_initialized) return 'Error: Linux no inicializado.\n';
    // First run apt-get update if it's an install
    if (args.startsWith('install') || args.startsWith('search')) {
      await runCommand('apt-get update -qq', timeout: const Duration(seconds: 60));
    }
    return runCommand('DEBIAN_FRONTEND=noninteractive apt-get $args -qq 2>&1 || true',
        timeout: const Duration(seconds: 120));
  }
}
