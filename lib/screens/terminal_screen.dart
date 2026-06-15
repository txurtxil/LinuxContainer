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
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _execute(String cmd, TerminalService term) {
    if (cmd.trim().isEmpty) return;
    term.executeCommand(cmd);
    _controller.clear();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          Consumer<TerminalService>(
            builder: (ctx, term, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(term.linuxMode ? 'Linux' : 'Shell',
                    style: const TextStyle(fontSize: 12)),
                IconButton(
                  icon: Icon(term.linuxMode ? Icons.article : Icons.terminal),
                  tooltip: 'Cambiar modo',
                  onPressed: () => term.toggleMode(),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: () => term.clear(),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Consumer<TerminalService>(
        builder: (ctx, term, _) {
          return Column(
            children: [
              // Output
              Expanded(
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.all(8),
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: term.lines.length,
                    itemBuilder: (ctx, i) {
                      final line = term.lines[i];
                      Color color;
                      if (line.isInput) color = Colors.greenAccent;
                      else if (line.isError) color = Colors.redAccent;
                      else color = const Color(0xFFE0E0E0);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line.text,
                          style: TextStyle(
                            color: color,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Input
              Container(
                padding: const EdgeInsets.all(8),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    Text('\$ ',
                        style: const TextStyle(
                            color: Colors.greenAccent,
                            fontFamily: 'monospace',
                            fontSize: 14)),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                        decoration: const InputDecoration.collapsed(
                            hintText: 'Escribe un comando...'),
                        onSubmitted: (cmd) => _execute(cmd, term),
                        enabled: !term.running,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: term.running
                          ? null
                          : () => _execute(_controller.text, term),
                      tooltip: 'Ejecutar',
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
