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

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _executeCommand(String cmd) {
    if (cmd.trim().isEmpty) return;

    final terminal = context.read<TerminalService>();
    final proot = context.read<ProotService>();
    // _history.add(cmd);

    if (cmd == 'clear') {
      terminal.clear();
      _inputController.clear();
      return;
    }

    if (cmd == 'exit') {
      terminal.addLine('Usa el botón atrás para salir.');
      _inputController.clear();
      return;
    }

    // Run command through proot or directly
    if (_useProot && proot.initialized) {
      proot.runCommand(cmd).then((output) {
        terminal.addLine(output);
      });
    } else if (_useProot && !proot.initialized) {
      terminal.addLine(
        'Linux no inicializado. Ve a Inicio y haz Setup primero.',
        type: TerminalLineType.error,
      );
    } else {
      terminal.execute(cmd);
    }

    _inputController.clear();
  }

  void _toggleMode() {
    setState(() {
      _useProot = !_useProot;
    });
    final terminal = context.read<TerminalService>();
    terminal.addLine(
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
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Limpiar',
            onPressed: terminal.clear,
          ),
          IconButton(
            icon: Icon(
              _useProot ? Icons.terminal : Icons.smartphone,
            ),
            tooltip: _useProot ? 'Cambiar a Shell Local' : 'Cambiar a Linux',
            onPressed: _toggleMode,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: _useProot && proot.initialized
                ? Colors.green.withValues(alpha: 0.2)
                : Colors.grey.withValues(alpha: 0.2),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: _useProot && proot.initialized ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  _useProot
                      ? (proot.initialized ? 'Linux Container' : 'No conectado')
                      : 'Shell Local',
                  style: theme.textTheme.labelSmall,
                ),
                const Spacer(),
                if (_useProot && proot.initialized)
                  Text(
                    'apt | ssh | net',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),

          // Terminal output
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
                            Icon(
                              Icons.terminal_rounded,
                              size: 48,
                              color: Colors.green.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Bienvenido a Terminal Linux',
                              style: TextStyle(
                                color: Colors.green.withValues(alpha: 0.7),
                                fontSize: 16,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _useProot && proot.initialized
                                  ? 'Escribe un comando y presiona Enter'
                                  : 'Activa el modo Linux Container para empezar',
                              style: TextStyle(
                                color: Colors.grey.withValues(alpha: 0.5),
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(12),
                        itemCount: terminal.lines.length,
                        itemBuilder: (context, index) {
                          final line = terminal.lines[index];
                          return SelectableText(
                            line.text,
                            style: TextStyle(
                              color: line.type == TerminalLineType.command
                                  ? Colors.greenAccent
                                  : line.type == TerminalLineType.error
                                      ? Colors.redAccent
                                      : Colors.green,
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.4,
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              border: Border(
                top: BorderSide(
                  color: Colors.green.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '\$ ',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    style: const TextStyle(
                      color: Colors.green,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onSubmitted: _executeCommand,
                    autofocus: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
