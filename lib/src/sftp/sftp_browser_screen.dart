// lib/src/sftp/sftp_browser_screen.dart
//
// Explorador visual de ficheros por SFTP: navegar tocando carpetas,
// descargar, eliminar, crear carpeta. Primera versión a propósito
// acotada — sin subir fichero ni renombrar todavía, para que lo que
// entra hoy se pueda probar de verdad antes de añadir más encima.

import 'dart:io';

import 'package:flutter/material.dart';

import '../ssh/ssh_host.dart';
import 'sftp_service.dart';
import 'sftp_favorites_service.dart';
import 'local_file_picker_screen.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class SftpBrowserScreen extends StatefulWidget {
  final SshHost host;
  final String rootfsPath;
  const SftpBrowserScreen({super.key, required this.host, required this.rootfsPath});

  @override
  State<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

enum _LoadState { connecting, ready, error }

class _SftpBrowserScreenState extends State<SftpBrowserScreen> {
  late final SftpService _svc;
  _LoadState _state = _LoadState.connecting;
  String _error = '';
  // Arranca en initialPath si el host lo tiene configurado; si no, en el
  // home del usuario remoto como siempre ('.' es lo que ya usaba sftp).
  late String _path = (widget.host.initialPath?.trim().isNotEmpty ?? false)
      ? widget.host.initialPath!.trim()
      : '.';
  List<SftpEntry> _entries = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _svc = SftpService(host: widget.host, rootfsPath: widget.rootfsPath);
    _connect();
  }

  @override
  void dispose() {
    _svc.close();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _state = _LoadState.connecting;
      _error = '';
    });
    try {
      await _svc.connect(
        onPasswordRequest: _askPassword,
        onHostKeyChanged: _warnHostKeyChanged,
      );
      await _load(_path);
      if (mounted) setState(() => _state = _LoadState.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _LoadState.error;
          _error = e.toString();
        });
      }
    }
  }

  Future<String> _askPassword() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('Contraseña de ${widget.host.username}@${widget.host.hostname}',
            style: const TextStyle(color: _C.textHi, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(
            filled: true,
            fillColor: _C.cardAlt,
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Conectar', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    return result ?? '';
  }

  Future<bool> _warnHostKeyChanged(String fingerprint) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('⚠ La huella del servidor cambió', style: TextStyle(color: _C.err, fontSize: 15)),
        content: Text(
          'La identidad de ${widget.host.hostname} no coincide con la que se guardó '
          'la primera vez. Puede ser que el servidor se reinstalara, o que algo '
          'intermedio se esté haciendo pasar por él.\n\nNueva huella:\n$fingerprint',
          style: const TextStyle(color: _C.textLo, fontSize: 12.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confiar de todos modos', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _load(String path) async {
    final entries = await _svc.list(path);
    if (mounted) setState(() { _path = path; _entries = entries; });
  }

  void _enter(SftpEntry e) {
    final next = _path == '.' ? e.name : '$_path/${e.name}';
    _load(next);
  }

  void _up() {
    if (_path == '.' || !_path.contains('/')) {
      _load('.');
    } else {
      _load(_path.substring(0, _path.lastIndexOf('/')));
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  Future<void> _download(SftpEntry e) async {
    final remote = _path == '.' ? e.name : '$_path/${e.name}';
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final local = await _svc.download(remote);
      messenger.showSnackBar(SnackBar(content: Text('Guardado en Descargas/xtr_sftp: $local')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Fallo al descargar: $err'), backgroundColor: _C.err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SftpEntry e) async {
    final remote = _path == '.' ? e.name : '$_path/${e.name}';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Eliminar?', style: TextStyle(color: _C.textHi)),
        content: Text(e.name, style: const TextStyle(color: _C.textLo)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await _svc.delete(remote, isDirectory: e.isDirectory);
      await _load(_path);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo eliminar: $err'), backgroundColor: _C.err));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Nueva carpeta', style: TextStyle(color: _C.textHi)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(filled: true, fillColor: _C.cardAlt, border: OutlineInputBorder(borderSide: BorderSide.none)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Crear', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final remote = _path == '.' ? name : '$_path/$name';
    try {
      await _svc.mkdir(remote);
      await _load(_path);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo crear: $err'), backgroundColor: _C.err));
      }
    }
  }

  void _showFabMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file, color: _C.accent),
              title: const Text('Subir archivo', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _uploadFile(); },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined, color: _C.accent),
              title: const Text('Nueva carpeta', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _newFolder(); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFile() async {
    final localPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const LocalFilePickerScreen()),
    );
    if (localPath == null || !mounted) return;

    final fileName = localPath.split('/').last;
    final remote = _path == '.' ? fileName : '$_path/$fileName';
    final localSize = await File(localPath).length();

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _svc.upload(localPath, remote);
      messenger.showSnackBar(SnackBar(
        content: Text('Subido: $fileName (${_fmtSize(localSize)})'),
      ));
      await _load(_path);
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Fallo al subir: $err'), backgroundColor: _C.err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFavorites() {
    final favs = SftpFavoritesService.instance.forHost(widget.host.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.star, color: Color(0xFFFFD60A), size: 18),
                  SizedBox(width: 8),
                  Text('Favoritos', style: TextStyle(color: _C.textHi, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (favs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Sin rutas guardadas todavia. Toca la estrella arriba para guardar la actual.',
                    style: TextStyle(color: _C.textLo, fontSize: 12)),
              ),
            ...favs.map((f) => ListTile(
                  leading: const Icon(Icons.folder, color: _C.accent, size: 20),
                  title: Text(f.label, style: const TextStyle(color: _C.textHi, fontSize: 13)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, color: _C.textLo, size: 18),
                    onPressed: () async {
                      await SftpFavoritesService.instance.remove(f.id);
                      Navigator.pop(ctx);
                    },
                  ),
                  onTap: () { Navigator.pop(ctx); _load(f.path); },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showActions(SftpEntry e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!e.isDirectory)
              ListTile(
                leading: const Icon(Icons.download, color: _C.accent),
                title: const Text('Descargar', style: TextStyle(color: _C.textHi)),
                onTap: () { Navigator.pop(ctx); _download(e); },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: _C.err),
              title: const Text('Eliminar', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _delete(e); },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: Text(widget.host.name, style: const TextStyle(color: _C.textHi, fontSize: 16)),
        actions: _state == _LoadState.ready
            ? [
                IconButton(
                  tooltip: 'Favoritos',
                  icon: const Icon(Icons.star_border, color: _C.textLo),
                  onPressed: _showFavorites,
                ),
                IconButton(
                  tooltip: SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                      ? 'Quitar de favoritos'
                      : 'Guardar esta ruta',
                  icon: Icon(
                    SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                        ? Icons.star
                        : Icons.star_outline,
                    color: SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                        ? const Color(0xFFFFD60A)
                        : _C.textLo,
                  ),
                  onPressed: () async {
                    await SftpFavoritesService.instance.toggle(widget.host.id, _path);
                    if (mounted) setState(() {});
                  },
                ),
              ]
            : null,
      ),
      body: _buildBody(),
      floatingActionButton: _state == _LoadState.ready
          ? FloatingActionButton(
              backgroundColor: _C.accent,
              onPressed: _showFabMenu,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_state == _LoadState.connecting) {
      return const Center(child: CircularProgressIndicator(color: _C.accent));
    }
    if (_state == _LoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _C.err, size: 40),
              const SizedBox(height: 12),
              Text(_error, style: const TextStyle(color: _C.textLo, fontSize: 12), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _connect,
                style: ElevatedButton.styleFrom(backgroundColor: _C.accent),
                child: const Text('Reintentar', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: _C.cardAlt,
          child: Row(
            children: [
              if (_path != '.')
                IconButton(icon: const Icon(Icons.arrow_upward, color: _C.textLo, size: 18), onPressed: _up),
              Expanded(
                child: Text(_path == '.' ? '/' : '/$_path',
                    style: const TextStyle(color: _C.textLo, fontSize: 12, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
              ),
              if (_busy)
                const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent)),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(_path),
            color: _C.accent,
            backgroundColor: _C.card,
            child: _entries.isEmpty
                ? ListView(children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('Carpeta vacía', style: TextStyle(color: _C.textLo))),
                    ),
                  ])
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      return ListTile(
                        leading: Icon(
                          e.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined,
                          color: e.isDirectory ? _C.accent : _C.textLo,
                        ),
                        title: Text(e.name, style: const TextStyle(color: _C.textHi, fontSize: 14)),
                        subtitle: e.isDirectory
                            ? null
                            : Text(_fmtSize(e.size), style: const TextStyle(color: _C.textLo, fontSize: 11)),
                        onTap: () => e.isDirectory ? _enter(e) : _showActions(e),
                        onLongPress: () => _showActions(e),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
