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
    final terminal = context.read<TerminalService>();
    final proot = context.read<ProotService>();

    if (cmd == 'clear') { terminal.clear(); _inputController.clear(); return; }
    if (cmd == 'exit') {
      terminal.addLine('Usa el boton atras para salir.');
      _inputController.clear(); return;
    }

    _running = true;
    terminal.addLine('\$ $cmd', type: TerminalLineType.command);
    _inputController.clear();

    try {
      String output;
      // Interceptar comandos apk/apt SIEMPRE si Linux esta inicializado
      if (cmd.startsWith('apk ') || cmd == 'apk') {
        if (proot.initialized) {
          output = await _handleApkCommand(cmd, proot, terminal);
        } else {
          output = 'Linux no inicializado. Ve a Inicio y haz Setup primero.';
        }
      } else if (cmd.startsWith('apt ') || cmd == 'apt') {
        output = 'Este contenedor usa Alpine Linux con apk como gestor de paquetes.\n'
                 'Usa: apk update, apk search <paquete>, apk add <paquete>, apk del <paquete>\n'
                 'Para buscar: apk search <termino>';
      } else if (_useProot && proot.initialized) {
        output = await proot.runShell(cmd, timeout: const Duration(seconds: 120));
        // Verificar si el comando fallo por ser binario musl
        if (output.contains('Permission denied') || output.contains('not found')) {
          final rootfs = proot.rootfsPath ?? '';
          if (rootfs.isNotEmpty) {
            final binPaths = ['/usr/bin', '/usr/sbin', '/bin', '/sbin', '/usr/local/bin'];
            for (final dir in binPaths) {
              final f = File('$rootfs$dir/${cmd.split(' ').first}');
              if (await f.exists()) {
                output += '\n⚠️ El binario "${cmd.split(' ').first}" existe pero es musl (incompatible con Android 15+).\n'
                         'Los binarios musl no pueden ejecutarse. Alternativas:\n'
                         '  - Usa toybox: vi en lugar de nano, sh en lugar de bash\n'
                         '  - Paquetes apk se instalan (datos/config) pero binarios no ejecutan\n';
                break;
              }
            }
          }
        }
      } else if (_useProot && !proot.initialized) {
        output = 'Linux no inicializado. Ve a Inicio y haz Setup primero.';
      } else {
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

  /// Intercepta comandos apk y los redirige al backend Dart
  Future<String> _handleApkCommand(String cmd, ProotService proot, TerminalService terminal) async {
    final parts = cmd.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[0] != 'apk') {
      return 'apk: uso: apk <comando> [args]\n'
             'Comandos: update, search, add, del, info, list\n'
             'Ej: apk search nano, apk add nano, apk del nano';
    }

    final subcmd = parts[1];
    switch (subcmd) {
      case 'update':
        await proot.refreshApkIndex();
        return 'APKINDEX actualizado: ${proot.apkIndex.length} paquetes disponibles';

      case 'search':
        if (parts.length < 3) return 'apk search: falta termino de busqueda';
        final q = parts.sublist(2).join(' ');
        final results = proot.searchPackages(q);
        if (results.isEmpty) return 'No se encontraron paquetes para: $q';
        final buf = StringBuffer('Resultados para: $q (${results.length})\n\n');
        for (final r in results) {
          final inst = proot.installedPackages.contains(r['name']) ? ' [instalado]' : '';
          buf.writeln('  ${r['name']} - ${r['version']}$inst');
        }
        buf.write('\nUsa: apk add <nombre> para instalar');
        return buf.toString();

      case 'add':
        if (parts.length < 3) return 'apk add: falta nombre del paquete';
        final pkg = parts[2];
        terminal.addLine('Instalando $pkg...');
        if (await proot.installApk(pkg)) {
          return 'OK $pkg instalado correctamente\n'
                 '⚠️ Los binarios musl no ejecutan en Android 15+';
        }
        return 'Error instalando $pkg';

      case 'del':
        if (parts.length < 3) return 'apk del: falta nombre del paquete';
        final dpkg = parts[2];
        if (await proot.removeApk(dpkg)) {
          return 'OK $dpkg eliminado';
        }
        return 'Error eliminando $dpkg';

      case 'info':
        if (parts.length < 3) return 'apk info: falta nombre del paquete';
        return proot.getPackageInfo(parts[2]);

      case 'list':
        final installed = proot.listInstalledPackages();
        if (installed.isEmpty) return 'No hay paquetes instalados';
        final buf = StringBuffer('Paquetes instalados (${installed.length}):\n\n');
        for (final p in installed) {
          buf.writeln('  ${p['name']} - ${p['version']}');
        }
        return buf.toString();

      default:
        return 'apk: comando desconocido: $subcmd\n'
               'Comandos: update, search, add, del, info, list';
    }
  }

  Future<String> _runLocal(String cmd) async {
    try {
      final result = await Process.run(
        '/system/bin/sh', ['-c', cmd],
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
    context.read<TerminalService>().addLine(
      _useProot ? '[Modo: Linux Container]' : '[Modo: Shell Local]',
      type: TerminalLineType.output,
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
                  child: SelectableText(proot.logText,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace', fontSize: 11, height: 1.3)),
                ),
              ),
            ),
          ],
        ),
      ),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: _useProot && proot.initialized
                ? Colors.green.withValues(alpha: 0.2)
                : Colors.grey.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8,
                    color: _useProot && proot.initialized ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Text(_useProot ? (proot.initialized ? 'Linux Container' : 'No conectado') : 'Shell Local',
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                if (_useProot && proot.initialized)
                  Text('apk | ssh | net',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (!_useProot)
                  Text('apk no disponible en este modo',
                      style: theme.textTheme.labelSmall?.copyWith(color: Colors.orange)),
              ],
            ),
          ),
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
                                style: TextStyle(color: Colors.green.withValues(alpha: 0.7),
                                    fontSize: 16, fontFamily: 'monospace')),
                            const SizedBox(height: 8),
                            Text(
                              _useProot && proot.initialized
                                  ? 'Comandos: apk, ls, ping, vi, netstat'
                                  : 'Cambia a Linux Container para usar apk',
                              style: TextStyle(color: Colors.grey.withValues(alpha: 0.5),
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
                          return SelectableText(line.text,
                              style: TextStyle(
                                color: line.type == TerminalLineType.command
                                    ? Colors.greenAccent
                                    : line.type == TerminalLineType.error
                                        ? Colors.redAccent
                                        : Colors.green,
                                fontFamily: 'monospace', fontSize: 13, height: 1.4));
                        },
                      ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              border: Border(top: BorderSide(color: Colors.green.withValues(alpha: 0.3), width: 1)),
            ),
            child: Row(
              children: [
                Text('\$ ',
                    style: TextStyle(
                      color: _running ? Colors.yellow : Colors.greenAccent,
                      fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.bold)),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    enabled: !_running,
                    style: const TextStyle(color: Colors.green, fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(
                      border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                    onSubmitted: _executeCommand,
                    autofocus: true,
                  ),
                ),
                if (_running)
                  const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
