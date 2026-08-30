// lib/src/sftp/local_file_picker_screen.dart
//
// Explorador del almacenamiento del PROPIO telefono, para elegir que
// fichero subir por SFTP. No es una libreria de terceros: es dart:io
// puro (Directory/File), el mismo patron que ya funciona en
// sftp_browser_screen.dart. MANAGE_EXTERNAL_STORAGE ya esta concedido
// (confirmado en el manifest), asi que no hace falta ningun dialogo de
// permisos adicional.
//
// Devuelve la ruta elegida via Navigator.pop(context, path), o null si se
// cancela.

import 'dart:io';
import 'package:flutter/material.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
}

class LocalFilePickerScreen extends StatefulWidget {
  const LocalFilePickerScreen({super.key});

  @override
  State<LocalFilePickerScreen> createState() => _LocalFilePickerScreenState();
}

class _LocalFilePickerScreenState extends State<LocalFilePickerScreen> {
  static const String _startDir = '/storage/emulated/0';

  String _currentPath = _startDir;
  List<FileSystemEntity> _entries = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(_startDir);
  }

  Future<void> _load(String path) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dir = Directory(path);
      final list = await dir.list().toList();
      list.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _currentPath = path;
          _entries = list;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo abrir esta carpeta: $e';
          _busy = false;
        });
      }
    }
  }

  void _up() {
    if (_currentPath == _startDir) return;
    final parent = Directory(_currentPath).parent.path;
    _load(parent.isEmpty ? _startDir : parent);
  }

  String _name(FileSystemEntity e) => e.path.split('/').last;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Elegir fichero', style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: _C.cardAlt,
            child: Row(
              children: [
                if (_currentPath != _startDir)
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: _C.textLo, size: 18),
                    onPressed: _up,
                  ),
                Expanded(
                  child: Text(
                    _currentPath,
                    style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_busy) return const Center(child: CircularProgressIndicator(color: _C.accent));
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: _C.textLo, fontSize: 12), textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('Carpeta vacia', style: TextStyle(color: _C.textLo)));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final isDir = e is Directory;
        return ListTile(
          leading: Icon(
            isDir ? Icons.folder : Icons.insert_drive_file_outlined,
            color: isDir ? _C.accent : _C.textLo,
          ),
          title: Text(_name(e), style: const TextStyle(color: _C.textHi, fontSize: 14)),
          onTap: () {
            if (isDir) {
              _load(e.path);
            } else {
              Navigator.of(context).pop(e.path);
            }
          },
        );
      },
    );
  }
}
