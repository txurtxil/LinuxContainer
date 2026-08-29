// lib/src/ssh/ssh_host.dart
//
// Una entrada de la lista de hosts, al estilo Termius: nombre, direccion,
// puerto, usuario, y opcionalmente una clave privada dentro del propio
// rootfs. No guarda contrasenas en texto plano a proposito — para eso esta
// la clave publica/privada o el agente ssh, no un campo "password" en JSON.
//
// JSON desde el dia uno, tal como se pidio: para poder exportar/importar/
// sincronizar mas adelante sin tener que migrar un formato distinto despues.

class SshHost {
  final String id;
  String name;
  String hostname;
  int port;
  String username;
  /// Ruta DENTRO del rootfs a una clave privada (p.ej. /root/.ssh/id_ed25519).
  /// Si es null, ssh usa lo que tenga configurado por defecto (agente,
  /// ~/.ssh/config, etc.) — igual que hacer `ssh usuario@host` a mano.
  String? keyPath;
  /// Para el icono de la lista: 'debian' | 'ubuntu' | 'raspbian' | 'generic'.
  String osTag;
  DateTime? lastUsed;

  SshHost({
    required this.id,
    required this.name,
    required this.hostname,
    this.port = 22,
    required this.username,
    this.keyPath,
    this.osTag = 'generic',
    this.lastUsed,
  });

  /// El comando ssh completo, listo para pasarselo a una TerminalSession.
  /// StrictHostKeyChecking=accept-new: en un cliente movil nadie va a
  /// teclear "yes" a mano en el prompt de host desconocido la primera vez;
  /// esto acepta hosts nuevos automaticamente sin desactivar la verificacion
  /// para hosts YA conocidos (que seguirian rechazandose si cambia la key).
  String toSshCommand() {
    final b = StringBuffer('ssh -o StrictHostKeyChecking=accept-new ');
    if (port != 22) b.write('-p $port ');
    if (keyPath != null && keyPath!.trim().isNotEmpty) {
      b.write('-i ${keyPath!.trim()} ');
    }
    b.write('$username@$hostname');
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostname': hostname,
        'port': port,
        'username': username,
        if (keyPath != null && keyPath!.isNotEmpty) 'keyPath': keyPath,
        'osTag': osTag,
        if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  static SshHost fromJson(Map<String, dynamic> j) => SshHost(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['hostname'] as String? ?? 'Host',
        hostname: j['hostname'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? 'root',
        keyPath: j['keyPath'] as String?,
        osTag: j['osTag'] as String? ?? 'generic',
        lastUsed: j['lastUsed'] != null ? DateTime.tryParse(j['lastUsed'] as String) : null,
      );

  SshHost copyWith({
    String? name,
    String? hostname,
    int? port,
    String? username,
    String? keyPath,
    String? osTag,
  }) {
    return SshHost(
      id: id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      keyPath: keyPath ?? this.keyPath,
      osTag: osTag ?? this.osTag,
      lastUsed: lastUsed,
    );
  }
}
