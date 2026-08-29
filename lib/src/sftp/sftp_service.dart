// lib/src/sftp/sftp_service.dart
//
// Conexión SFTP real, vía dartssh2 — un camino de código TOTALMENTE
// DISTINTO al de SSH/terminal de esta noche. Aquello reutilizaba proot y el
// Pty; esto es una conexión TCP directa desde el propio proceso de la app,
// sin pasar por proot en absoluto. Por eso las rutas de clave (SshHost.keyPath,
// pensadas para el "ssh" de dentro del shell) hay que traducirlas al disco
// real anteponiendo el rootfsPath.
//
// Verificación de host key: propia, en JSON, independiente del
// known_hosts real de OpenSSH (que usa la sesión ssh normal). Primera vez
// que se ve un host, se confía y se recuerda su huella; si cambia después,
// se avisa y se rechaza — mismo espíritu que accept-new en la CLI, pero
// aplicado a esta conexión aparte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/ssh_host.dart';

class SftpEntry {
  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final int size;
  final DateTime? modified;

  SftpEntry({
    required this.name,
    required this.isDirectory,
    required this.isSymlink,
    required this.size,
    this.modified,
  });
}

class SftpService {
  static const String _knownHostsRel = '/root/.xtr/sftp_known_hosts.json';
  static const String _downloadDirAbs = '/storage/emulated/0/Download/xtr_sftp';

  final SshHost host;
  final String rootfsPath;

  SSHClient? _client;
  SftpClient? _sftp;

  SftpService({required this.host, required this.rootfsPath});

  bool get isConnected => _sftp != null;

  Future<Map<String, String>> _loadKnownHosts() async {
    try {
      final f = File('$rootfsPath$_knownHostsRel');
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveKnownHosts(Map<String, String> hosts) async {
    try {
      final f = File('$rootfsPath$_knownHostsRel');
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(hosts));
    } catch (_) {}
  }

  /// [onPasswordRequest] se llama solo si el host no tiene clave configurada.
  /// [onHostKeyChanged] se llama si la huella guardada NO coincide con la
  /// que presenta el servidor ahora — señal de posible suplantación, o de
  /// que el servidor se reinstaló. Devuelve true para confiar de todos
  /// modos (y sobrescribir lo guardado).
  Future<void> connect({
    required Future<String> Function() onPasswordRequest,
    required Future<bool> Function(String fingerprint) onHostKeyChanged,
  }) async {
    if (isConnected) return;

    final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(const Duration(seconds: 12));

    List<SSHKeyPair>? identities;
    if (host.keyPath != null && host.keyPath!.trim().isNotEmpty) {
      final keyFile = File('$rootfsPath${host.keyPath}');
      if (await keyFile.exists()) {
        identities = SSHKeyPair.fromPem(await keyFile.readAsString());
      }
    }

    final knownHosts = await _loadKnownHosts();
    final hostKey = '${host.hostname}:${host.port}';

    _client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest:
          identities == null ? () => onPasswordRequest() : null,
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = '$type:${base64.encode(fingerprintBytes)}';
        final saved = knownHosts[hostKey];
        if (saved == null) {
          knownHosts[hostKey] = fingerprint;
          await _saveKnownHosts(knownHosts);
          return true;
        }
        if (saved == fingerprint) return true;
        final trustAnyway = await onHostKeyChanged(fingerprint);
        if (trustAnyway) {
          knownHosts[hostKey] = fingerprint;
          await _saveKnownHosts(knownHosts);
        }
        return trustAnyway;
      },
    );

    await _client!.authenticated;
    _sftp = await _client!.sftp();
  }

  Future<List<SftpEntry>> list(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    final items = await sftp.listdir(path);
    return items
        .where((i) => i.filename != '.' && i.filename != '..')
        .map((i) => SftpEntry(
              name: i.filename,
              isDirectory: i.attr.isDirectory,
              isSymlink: i.attr.isSymbolicLink,
              size: i.attr.size ?? 0,
              modified: i.attr.modifyTime != null
                  ? DateTime.fromMillisecondsSinceEpoch(i.attr.modifyTime! * 1000)
                  : null,
            ))
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  /// Descarga a Descargas/xtr_sftp/<host>/<ruta>. Devuelve la ruta local
  /// final. [onProgress] recibe bytes descargados hasta ahora.
  Future<String> download(String remotePath, {void Function(int bytes)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    final safeHost = host.name.replaceAll(RegExp(r'[^\w\-]'), '_');
    final fileName = remotePath.split('/').last;
    final dir = Directory('$_downloadDirAbs/$safeHost');
    await dir.create(recursive: true);
    final localPath = '${dir.path}/$fileName';

    final sink = File(localPath).openWrite();
    await sftp.download(remotePath, sink, onProgress: onProgress, closeDestination: true);
    return localPath;
  }

  Future<void> delete(String remotePath, {required bool isDirectory}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    if (isDirectory) {
      await sftp.rmdir(remotePath);
    } else {
      await sftp.remove(remotePath);
    }
  }

  Future<void> mkdir(String remotePath) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    await sftp.mkdir(remotePath);
  }

  Future<void> close() async {
    try {
      _client?.close();
      await _client?.done;
    } catch (_) {}
    _client = null;
    _sftp = null;
  }
}
