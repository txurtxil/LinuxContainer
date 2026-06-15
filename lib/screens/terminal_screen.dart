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
  int _historyIndex = -1;

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
    _historyIndex = _history.length;
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
      if (_useProot && proot.initialized) {
        output = await proot.runShell(cmd,
            timeout: const Duration(seconds: 120));
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terminal = context.watch<TerminalService>();
    final proot = context.watch<ProotService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_useProot ? 'Terminal Linux' : 'Terminal Local'),
        actions: [
          if (_useProot)
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
                            Text(_useProot && proot.initialized
                                ? 'Escribe un comando y presiona Enter'
                                : 'Activa el modo Linux Container',
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
}
