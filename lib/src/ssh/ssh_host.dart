// lib/src/ssh/ssh_host.dart
//
// Una entrada de la lista de hosts, al estilo Termius: nombre, direccion,
// puerto, usuario, y opcionalmente una clave privada dentro del propio
// rootfs. NO guarda contrasenas -- para eso esta SshCredentialsStore,
// separado, en almacenamiento cifrado del sistema (Keystore de Android via
// flutter_secure_storage), no en este JSON plano.
//
// JSON desde el dia uno: para poder exportar/importar/sincronizar mas
// adelante sin tener que migrar un formato distinto despues.

class SshHost {
  final String id;
  String name;
  String hostname;
  int port;
  String username;
  /// Ruta DENTRO del rootfs a una clave privada (p.ej. /root/.ssh/id_ed25519).
  String? keyPath;
  /// Directorio inicial al conectar (p.ej. "/", "/var/www"). Si es null o
  /// vacio, se usa el home del usuario remoto, como siempre.
  String? initialPath;
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
    this.initialPath,
    this.osTag = 'generic',
    this.lastUsed,
  });

  /// El comando ssh completo, listo para pasarselo a una TerminalSession.
  ///
  /// StrictHostKeyChecking=accept-new: en un cliente movil nadie va a
  /// teclear "yes" a mano en el prompt de host desconocido la primera vez;
  /// esto acepta hosts nuevos automaticamente sin desactivar la verificacion
  /// para hosts YA conocidos (que seguirian rechazandose si cambia la key).
  ///
  /// Si hay initialPath, se fuerza -t (pseudo-tty) y se pasa un comando
  /// remoto que hace cd y luego exec de un shell de login -- eso deja una
  /// sesion interactiva normal, solo que arrancando en otro sitio. El path
  /// va entre comillas dobles dentro de un bloque de comillas simples, asi
  /// que sobrevive espacios; una comilla simple DENTRO del path es el unico
  /// caso raro que esto no cubre.
  String toSshCommand() {
    final b = StringBuffer('ssh -o StrictHostKeyChecking=accept-new ');
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostname': hostname,
        'port': port,
        'username': username,
        if (keyPath != null && keyPath!.isNotEmpty) 'keyPath': keyPath,
        if (initialPath != null && initialPath!.isNotEmpty) 'initialPath': initialPath,
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
        initialPath: j['initialPath'] as String?,
        osTag: j['osTag'] as String? ?? 'generic',
        lastUsed: j['lastUsed'] != null ? DateTime.tryParse(j['lastUsed'] as String) : null,
      );

  SshHost copyWith({
    String? name,
    String? hostname,
    int? port,
    String? username,
    String? keyPath,
    String? initialPath,
    String? osTag,
  }) {
    return SshHost(
      id: id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      keyPath: keyPath ?? this.keyPath,
      initialPath: initialPath ?? this.initialPath,
      osTag: osTag ?? this.osTag,
      lastUsed: lastUsed,
    );
  }
}
