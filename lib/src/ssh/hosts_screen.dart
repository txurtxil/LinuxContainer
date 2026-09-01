// lib/src/ssh/hosts_screen.dart
//
// Lista de hosts, al estilo Termius de la captura: icono, nombre, y
// "usuario@host:puerto" debajo. Deliberadamente NO sabe nada de terminales
// ni de proot — solo gestiona la lista y avisa via onConnect(host) cuando
// tocas uno. Quien la use decide que hacer con eso (abrir una pestana con
// `ssh ...` es la idea, pero esta pantalla no lo impone).

import 'package:flutter/material.dart';
import 'ssh_host.dart';
import 'ssh_hosts_service.dart';
import 'ssh_credentials_store.dart';
import '../sftp/sftp_browser_screen.dart';
import '../sftp/sftp_connection_pool.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
}

const Map<String, Color> _osColors = {
  'debian': Color(0xFFD70A53),
  'ubuntu': Color(0xFFE95420),
  'raspbian': Color(0xFFC51A4A),
  'generic': Color(0xFF2D5F8A),
};

const Map<String, IconData> _osIcons = {
  'debian': Icons.blur_circular,
  'ubuntu': Icons.blur_circular,
  'raspbian': Icons.blur_circular,
  'generic': Icons.dns_rounded,
};

class HostsScreen extends StatefulWidget {
  final void Function(SshHost host) onConnect;
  /// Si se pasa, cada host muestra un icono extra para abrir el explorador
  /// SFTP directamente (sin pasar por una pestaña de terminal).
  final String? rootfsPath;
  /// Callback DISTINTO de onConnect para cuando "Abrir terminal SSH" se
  /// pulsa DESDE DENTRO del explorador SFTP (no desde esta lista). onConnect
  /// ya trae su propio pop() pensado para cerrar solo esta pantalla; desde
  /// el explorador hay una pantalla mas de por medio, asi que hace falta
  /// una navegacion distinta (quien la reciba decide cuanto cerrar).
  final void Function(SshHost host)? onOpenTerminalFromSftp;
  const HostsScreen({
    super.key,
    required this.onConnect,
    this.rootfsPath,
    this.onOpenTerminalFromSftp,
  });

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  final _svc = SshHostsService.instance;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _svc.hosts;
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        title: const Text('Hosts', style: TextStyle(color: _C.textHi)),
        iconTheme: const IconThemeData(color: _C.textHi),
        actions: [
          IconButton(
            tooltip: 'Cerrar todas las conexiones SFTP',
            icon: const Icon(Icons.link_off, color: _C.textLo),
            onPressed: () async {
              await SftpConnectionPool.instance.disconnectAll();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: hosts.isEmpty
          ? Center(
              child: Text('Sin hosts todavía · toca + para añadir uno',
                  style: const TextStyle(color: _C.textLo, fontSize: 13)),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: hosts.length,
              itemBuilder: (context, i) => _hostTile(hosts[i]),
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _C.accent,
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _hostTile(SshHost h) {
    final color = _osColors[h.osTag] ?? _osColors['generic']!;
    final icon = _osIcons[h.osTag] ?? _osIcons['generic']!;
    return Dismissible(
      key: ValueKey(h.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: _C.err,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(h),
      onDismissed: (_) => _svc.remove(h.id),
      child: ListTile(
        onTap: () async {
          await _svc.touch(h.id);
          widget.onConnect(h);
        },
        onLongPress: () => _openEditor(existing: h),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
        title: Text(h.name, style: const TextStyle(color: _C.textHi, fontWeight: FontWeight.w500)),
        subtitle: Text(
          '${h.username}@${h.hostname}${h.port != 22 ? ':${h.port}' : ''}',
          style: const TextStyle(color: _C.textLo, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.rootfsPath != null)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(Icons.folder_open, color: _C.textLo, size: 20),
                    tooltip: 'Explorar archivos (SFTP)',
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SftpBrowserScreen(
                        host: h,
                        rootfsPath: widget.rootfsPath!,
                        onOpenTerminal: widget.onOpenTerminalFromSftp,
                      ),
                    )).then((_) {
                      // Al volver puede haber cambiado el estado de conexion
                      // (por ejemplo, si se desconecto desde dentro).
                      if (mounted) setState(() {});
                    }),
                  ),
                  if (SftpConnectionPool.instance.isConnected(h.id))
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
            const Icon(Icons.chevron_right, color: _C.textLo),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(SshHost h) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Eliminar host?', style: TextStyle(color: _C.textHi)),
        content: Text(h.name, style: const TextStyle(color: _C.textLo)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    return r ?? false;
  }

  void _openEditor({SshHost? existing}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _HostEditorSheet(existing: existing),
    );
  }
}

class _HostEditorSheet extends StatefulWidget {
  final SshHost? existing;
  const _HostEditorSheet({this.existing});

  @override
  State<_HostEditorSheet> createState() => _HostEditorSheetState();
}

class _HostEditorSheetState extends State<_HostEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _hostname;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _keyPath;
  late final TextEditingController _password;
  late final TextEditingController _initialPath;
  String _osTag = 'generic';
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _hostname = TextEditingController(text: e?.hostname ?? '');
    _port = TextEditingController(text: (e?.port ?? 22).toString());
    _username = TextEditingController(text: e?.username ?? 'root');
    _keyPath = TextEditingController(text: e?.keyPath ?? '');
    _initialPath = TextEditingController(text: e?.initialPath ?? '');
    _password = TextEditingController();
    _osTag = e?.osTag ?? 'generic';

    // La contrasena vive en almacenamiento cifrado, no en el host -- se
    // carga aparte y de forma asincrona. Un host nuevo no tiene id todavia,
    // asi que no hay nada que cargar hasta la primera vez que se guarde.
    if (e != null) {
      SshCredentialsStore.readPassword(e.id).then((pwd) {
        if (mounted && pwd != null) setState(() => _password.text = pwd);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _hostname.dispose();
    _port.dispose();
    _username.dispose();
    _keyPath.dispose();
    _password.dispose();
    _initialPath.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: _C.textLo),
        hintStyle: const TextStyle(color: _C.textLo),
        filled: true,
        fillColor: _C.cardAlt,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      );

  Future<void> _save() async {
    final hostname = _hostname.text.trim();
    final username = _username.text.trim();
    if (hostname.isEmpty || username.isEmpty) return;

    final name = _name.text.trim().isEmpty ? hostname : _name.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    final keyPath = _keyPath.text.trim();
    final initialPath = _initialPath.text.trim();
    final password = _password.text;

    String hostId;
    if (widget.existing != null) {
      hostId = widget.existing!.id;
      await SshHostsService.instance.update(widget.existing!.copyWith(
        name: name, hostname: hostname, port: port, username: username,
        keyPath: keyPath.isEmpty ? null : keyPath,
        initialPath: initialPath.isEmpty ? null : initialPath,
        osTag: _osTag,
      ));
    } else {
      hostId = SshHostsService.instance.newId();
      await SshHostsService.instance.add(SshHost(
        id: hostId,
        name: name, hostname: hostname, port: port, username: username,
        keyPath: keyPath.isEmpty ? null : keyPath,
        initialPath: initialPath.isEmpty ? null : initialPath,
        osTag: _osTag,
      ));
    }

    // Contrasena aparte, cifrada -- nunca dentro del objeto SshHost.
    await SshCredentialsStore.savePassword(hostId, password);

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: _C.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.existing == null ? 'Nuevo host' : 'Editar host',
                  style: const TextStyle(color: _C.textHi, fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              TextField(controller: _name, style: const TextStyle(color: _C.textHi),
                  decoration: _dec('Nombre', hint: 'RPi5, opcional — usa el host si se deja vacío')),
              const SizedBox(height: 10),
              TextField(controller: _hostname, style: const TextStyle(color: _C.textHi),
                  decoration: _dec('Host', hint: '192.168.10.140 o dominio')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  flex: 2,
                  child: TextField(controller: _username, style: const TextStyle(color: _C.textHi),
                      decoration: _dec('Usuario')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _port, keyboardType: TextInputType.number,
                      style: const TextStyle(color: _C.textHi), decoration: _dec('Puerto')),
                ),
              ]),
              const SizedBox(height: 10),
              TextField(controller: _keyPath, style: const TextStyle(color: _C.textHi),
                  decoration: _dec('Clave privada (opcional)', hint: '/root/.ssh/id_ed25519')),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                obscureText: _obscurePassword,
                style: const TextStyle(color: _C.textHi),
                decoration: _dec('Contrasena (opcional)', hint: 'Se guarda cifrada, no en texto plano').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: _C.textLo, size: 18),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  'Se usa en el explorador de archivos (SFTP). En una pestana de terminal '
                  'normal seguiras tecleandola tu, como en cualquier ssh.',
                  style: TextStyle(color: _C.textLo, fontSize: 10.5),
                ),
              ),
              const SizedBox(height: 10),
              TextField(controller: _initialPath, style: const TextStyle(color: _C.textHi),
                  decoration: _dec('Carpeta inicial (opcional)', hint: '/  o  /var/www')),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: _osColors.keys.map((tag) {
                  final selected = tag == _osTag;
                  return ChoiceChip(
                    label: Text(tag),
                    selected: selected,
                    onSelected: (_) => setState(() => _osTag = tag),
                    selectedColor: _osColors[tag],
                    backgroundColor: _C.cardAlt,
                    labelStyle: TextStyle(color: selected ? Colors.white : _C.textLo, fontSize: 12),
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(backgroundColor: _C.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text(widget.existing == null ? 'Añadir' : 'Guardar', style: const TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
