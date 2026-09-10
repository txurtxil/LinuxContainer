import 'dart:convert';

class SshHost {
  final String id;
  String name;
  String hostname;
  int port;
  String username;
  String? keyPath;
  String? initialPath;
  String osTag;
  DateTime? lastUsed;

  SshHost({
    required this.id, required this.name, required this.hostname, this.port = 22,
    required this.username, this.keyPath, this.initialPath, this.osTag = 'generic', this.lastUsed,
  });

  String toSshCommand() {
    // TCPKeepAlive=no evita cortes por inactividad a nivel kernel.
    // ServerAliveInterval=120 y Max=15 otorgan ~30 minutos de tolerancia al cambiar de app.
    final b = StringBuffer('ssh -o StrictHostKeyChecking=accept-new -o TCPKeepAlive=no -o ServerAliveInterval=120 -o ServerAliveCountMax=15 ');
    if (port != 22) b.write('-p $port ');
    if (keyPath != null && keyPath!.trim().isNotEmpty) {
      b.write('-i ${keyPath!.trim()} ');
    }

    final dir = initialPath?.trim();
    if (dir != null && dir.isNotEmpty) {
      b.write('-t $username@$hostname ');
      b.write("'cd \"$dir\" 2>/dev/null || cd; exec \${SHELL:-bash} -l'");
    } else {
      b.write('$username@$hostname');
    }
    return b.toString();
  }

  String toSshCommandWithPassfile(String passFile) {
    final ssh = toSshCommand();
    return 'if ! command -v sshpass >/dev/null 2>&1; then '
        'apt-get update -qq >/dev/null 2>&1; '
        'apt-get install -y -qq sshpass >/dev/null 2>&1; '
        'fi; '
        'if command -v sshpass >/dev/null 2>&1; then '
        'exec sshpass -f "$passFile" $ssh; '
        'else exec $ssh; fi';
  }

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'hostname': hostname, 'port': port, 'username': username,
        if (keyPath != null && keyPath!.isNotEmpty) 'keyPath': keyPath,
        if (initialPath != null && initialPath!.isNotEmpty) 'initialPath': initialPath,
        'osTag': osTag, if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  static SshHost fromJson(Map<String, dynamic> j) => SshHost(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['hostname'] as String? ?? 'Host',
        hostname: j['hostname'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? 'root',
        keyPath: j['keyPath'] as String?,
        initialPath: j['initialPath'] as String?,
        osTag: j['osTag'] as String? ?? 'generic',
        lastUsed: j['lastUsed'] != null ? DateTime.tryParse(j['lastUsed'] as String) : null,
      );

  SshHost copyWith({
    String? name, String? hostname, int? port, String? username,
    String? keyPath, String? initialPath, String? osTag,
  }) {
    return SshHost(
      id: id, name: name ?? this.name, hostname: hostname ?? this.hostname, port: port ?? this.port,
      username: username ?? this.username, keyPath: keyPath ?? this.keyPath,
      initialPath: initialPath ?? this.initialPath, osTag: osTag ?? this.osTag, lastUsed: lastUsed,
    );
  }
}
