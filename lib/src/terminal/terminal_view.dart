// lib/src/terminal/terminal_view.dart
// TerminalView — Vista principal de la terminal proot con menú contextual
// Incluye: Setup Inicial, gestión de sesión, accesos rápidos

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalView extends StatefulWidget {
  const TerminalView({super.key});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  static const _channel = MethodChannel('xtr/main');

  final _outputController = ScrollController();
  final _inputController  = TextEditingController();
  final _inputFocus       = FocusNode();
  final _outputLines      = <_OutputLine>[];

  bool _rootfsReady     = false;
  bool _isRunning       = false;
  bool _setupInProgress = false;
  String _rootfsPath    = '';

  // Historial de comandos
  final _history      = <String>[];
  int   _historyIndex = -1;

  @override
  void initState() {
    super.initState();
    _checkRootfsStatus();
  }

  @override
  void dispose() {
    _outputController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Estado del rootfs ────────────────────────────────────
  Future<void> _checkRootfsStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('getRootfsStatus');
      setState(() {
        _rootfsReady = result?['extracted'] as bool? ?? false;
        _rootfsPath  = result?['path'] as String? ?? '';
      });

      if (_rootfsReady) {
        _addLine('Sistema Debian listo en $_rootfsPath', LineType.info);
        _addLine('Escribe un comando o usa el menú ☰', LineType.info);
      } else {
        _addLine('⚠ Sistema Debian no instalado', LineType.warning);
        _addLine('Usa el menú ☰ → "Setup Inicial" para configurar', LineType.warning);
      }
    } catch (e) {
      _addLine('Error comprobando rootfs: $e', LineType.error);
    }
  }

  // ── Output lines ─────────────────────────────────────────
  void _addLine(String text, [LineType type = LineType.output]) {
    setState(() {
      _outputLines.add(_OutputLine(text, type));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputController.hasClients) {
        _outputController.animateTo(
          _outputController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Ejecutar comando ─────────────────────────────────────
  Future<void> _runCommand(String cmd) async {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return;

    _history.insert(0, trimmed);
    _historyIndex = -1;
    _inputController.clear();

    _addLine('❯ $trimmed', LineType.command);
    setState(() => _isRunning = true);

    try {
      final output = await _channel.invokeMethod<String>(
        'runInProot',
        {'command': trimmed},
      );
      if (output != null && output.isNotEmpty) {
        for (final line in output.split('\n')) {
          if (line.isNotEmpty) _addLine(line);
        }
      }
    } on PlatformException catch (e) {
      _addLine('Error: ${e.message}', LineType.error);
    } finally {
      setState(() => _isRunning = false);
      _inputFocus.requestFocus();
    }
  }

  // ── Setup Inicial ─────────────────────────────────────────
  Future<void> _runSetupInicial() async {
    if (_setupInProgress) return;

    // Si rootfs no está extraído, extraerlo primero
    if (!_rootfsReady) {
      final confirmed = await _showConfirmDialog(
        'Primer arranque',
        'Se descomprimirá el sistema Debian (~500 MB).\nEsto puede tardar 2-3 minutos.',
      );
      if (!confirmed) return;

      _addLine('Extrayendo sistema Debian...', LineType.info);
      setState(() => _setupInProgress = true);

      try {
        final result = await _channel.invokeMethod<Map>('extractRootfs');
        final success = result?['success'] as bool? ?? false;
        if (success) {
          setState(() => _rootfsReady = true);
          _addLine('✓ Sistema Debian extraído', LineType.success);
        } else {
          _addLine('✗ Error: ${result?["error"]}', LineType.error);
          setState(() => _setupInProgress = false);
          return;
        }
      } catch (e) {
        _addLine('✗ Error al extraer: $e', LineType.error);
        setState(() => _setupInProgress = false);
        return;
      }
    }

    // Ejecutar xtr_setup.sh dentro de proot
    _addLine('', LineType.info);
    _addLine('═══════════════════════════════════', LineType.info);
    _addLine('  XTR Terminal — Setup Inicial', LineType.info);
    _addLine('═══════════════════════════════════', LineType.info);
    _addLine('Ejecutando configuración del sistema...', LineType.info);
    _addLine('(apt update, smolagents, agent server)', LineType.info);
    _addLine('Esto puede tardar 5-10 minutos.', LineType.warning);
    _addLine('', LineType.info);

    setState(() { _setupInProgress = true; _isRunning = true; });

    try {
      // Paso 1: apt update + upgrade
      _addLine('▶ Actualizando paquetes...', LineType.info);
      await _runSilentCommand('apt update -q && apt upgrade -y -q 2>&1 | tail -3');

      // Paso 2: Paquetes base
      _addLine('▶ Instalando herramientas base...', LineType.info);
      await _runSilentCommand(
        'DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends '
        'python3 python3-pip python3-venv python3-dev '
        'git curl wget ca-certificates build-essential nano 2>&1 | tail -3'
      );

      // Paso 3: smolagents
      _addLine('▶ Instalando smolagents...', LineType.info);
      await _runSilentCommand(
        'cd /root && python3 -m venv agent-env && '
        'agent-env/bin/pip install -q --upgrade pip && '
        'agent-env/bin/pip install -q smolagents fastapi "uvicorn[standard]" httpx openai requests'
      );

      // Paso 4: Verificar agent_server.py
      _addLine('▶ Verificando agent server...', LineType.info);
      final agentCheck = await _channel.invokeMethod<String>(
        'runInProot',
        {'command': 'test -f /root/agent_server.py && echo "OK" || echo "MISSING"'},
      );
      if (agentCheck?.trim() == 'MISSING') {
        _addLine('  agent_server.py no encontrado — descargando...', LineType.warning);
        await _runSilentCommand(
          'curl -fsSL https://raw.githubusercontent.com/txurtxil/LinuxContainer/main/assets/agent_server.py '
          '-o /root/agent_server.py 2>&1'
        );
      }

      // Paso 5: start_agent.sh
      await _runSilentCommand(
        'cat > /root/start_agent.sh << \'EOF\'\n'
        '#!/bin/bash\n'
        'source /root/agent-env/bin/activate\n'
        'cd /root\n'
        'uvicorn agent_server:app --host 127.0.0.1 --port 8765 --workers 1\n'
        'EOF\n'
        'chmod +x /root/start_agent.sh'
      );

      // Mostrar versiones instaladas
      final versions = await _channel.invokeMethod<String>(
        'runInProot',
        {'command':
          'echo "Python: $(python3 --version)" && '
          'echo "smolagents: $(/root/agent-env/bin/pip show smolagents 2>/dev/null | grep Version || echo N/A)" && '
          'echo "FastAPI: $(/root/agent-env/bin/pip show fastapi 2>/dev/null | grep Version || echo N/A)"'
        },
      );

      _addLine('', LineType.info);
      _addLine('✓ Setup completado', LineType.success);
      if (versions != null) {
        for (final v in versions.split('\n')) {
          if (v.isNotEmpty) _addLine('  $v', LineType.success);
        }
      }
      _addLine('', LineType.info);
      _addLine('Los modelos GPU (.task) se gestionan', LineType.info);
      _addLine('desde la pantalla "Prueba GPU" de la app.', LineType.info);

    } catch (e) {
      _addLine('✗ Error durante el setup: $e', LineType.error);
    } finally {
      setState(() { _setupInProgress = false; _isRunning = false; });
    }
  }

  Future<void> _runSilentCommand(String cmd) async {
    try {
      final output = await _channel.invokeMethod<String>(
        'runInProot',
        {'command': cmd},
      );
      if (output != null && output.isNotEmpty) {
        for (final line in output.split('\n')) {
          if (line.isNotEmpty) _addLine('  $line');
        }
      }
    } on PlatformException catch (e) {
      _addLine('  ⚠ ${e.message}', LineType.warning);
    }
  }

  // ── Menú contextual ───────────────────────────────────────
  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _MenuSheet(
        rootfsReady: _rootfsReady,
        onSetupInicial: () {
          Navigator.pop(context);
          _runSetupInicial();
        },
        onClearOutput: () {
          Navigator.pop(context);
          setState(() => _outputLines.clear());
        },
        onBash: () {
          Navigator.pop(context);
          _runCommand('bash --version');
        },
        onStartAgent: () {
          Navigator.pop(context);
          _runCommand('bash /root/start_agent.sh');
        },
        onCheckVersions: () {
          Navigator.pop(context);
          _runCommand(
            'echo "=== Sistema ===" && '
            'uname -a && '
            'echo "=== Python ===" && '
            'python3 --version && '
            'echo "=== smolagents ===" && '
            '/root/agent-env/bin/pip show smolagents 2>/dev/null || echo "N/A"'
          );
        },
      ),
    );
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    return await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar', style: TextStyle(color: Color(0xFF00D4FF))),
          ),
        ],
      ),
    ) ?? false;
  }

  // ── Build ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            Icon(
              _rootfsReady ? Icons.terminal : Icons.warning_amber,
              color: _rootfsReady ? const Color(0xFF00D4FF) : Colors.orange,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              _rootfsReady ? 'Terminal Debian' : 'Terminal — Sin sistema',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            if (_isRunning) ...[
              const SizedBox(width: 12),
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF00D4FF),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu, color: Colors.white70),
            onPressed: _showMenu,
            tooltip: 'Menú',
          ),
        ],
      ),

      body: Column(
        children: [
          // ── Salida ─────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              controller: _outputController,
              padding: const EdgeInsets.all(8),
              itemCount: _outputLines.length,
              itemBuilder: (_, i) {
                final line = _outputLines[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: line.color,
                      height: 1.4,
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Barra de atajos ────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final shortcut in ['Tab', 'Ctrl+C', 'ls', 'cd ~', 'pwd', 'clear'])
                  _ShortcutChip(
                    label: shortcut,
                    onTap: () {
                      if (shortcut == 'clear') {
                        setState(() => _outputLines.clear());
                      } else if (shortcut == 'Ctrl+C') {
                        _addLine('^C', LineType.warning);
                      } else {
                        _runCommand(shortcut);
                      }
                    },
                  ),
              ],
            ),
          ),

          // ── Input ─────────────────────────────────────────
          Container(
            color: const Color(0xFF1A1A2E),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text(
                  '❯ ',
                  style: TextStyle(
                    color: Color(0xFF00D4FF),
                    fontFamily: 'monospace',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'comando...',
                      hintStyle: TextStyle(color: Colors.white30),
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onSubmitted: _runCommand,
                    enabled: !_isRunning,
                    onChanged: (_) => setState(() => _historyIndex = -1),
                    onEditingComplete: () {},
                  ),
                ),
                // Historial
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.white38),
                  onPressed: () {
                    if (_history.isEmpty) return;
                    setState(() {
                      _historyIndex = (_historyIndex + 1).clamp(0, _history.length - 1);
                      _inputController.text = _history[_historyIndex];
                      _inputController.selection = TextSelection.collapsed(
                          offset: _inputController.text.length);
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                // Enviar
                IconButton(
                  icon: const Icon(Icons.send, size: 18, color: Color(0xFF00D4FF)),
                  onPressed: _isRunning ? null : () => _runCommand(_inputController.text),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),

          SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
        ],
      ),
    );
  }
}

// ── Menú bottom sheet ─────────────────────────────────────────
class _MenuSheet extends StatelessWidget {
  final bool rootfsReady;
  final VoidCallback onSetupInicial;
  final VoidCallback onClearOutput;
  final VoidCallback onBash;
  final VoidCallback onStartAgent;
  final VoidCallback onCheckVersions;

  const _MenuSheet({
    required this.rootfsReady,
    required this.onSetupInicial,
    required this.onClearOutput,
    required this.onBash,
    required this.onStartAgent,
    required this.onCheckVersions,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // ── Setup Inicial — siempre visible y destacado ───
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00D4FF), Color(0xFF7B2FBE)],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: const Icon(Icons.rocket_launch, color: Colors.white),
              title: const Text(
                'Setup Inicial',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                rootfsReady
                  ? 'Instala/actualiza smolagents y herramientas'
                  : 'Extrae Debian + configura el sistema',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              onTap: onSetupInicial,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          const Divider(color: Colors.white12, height: 24, indent: 16, endIndent: 16),

          // ── Resto de opciones ─────────────────────────────
          _MenuItem(
            icon: Icons.play_arrow,
            label: 'Iniciar agente (puerto 8765)',
            enabled: rootfsReady,
            onTap: onStartAgent,
          ),
          _MenuItem(
            icon: Icons.info_outline,
            label: 'Versiones instaladas',
            enabled: rootfsReady,
            onTap: onCheckVersions,
          ),
          _MenuItem(
            icon: Icons.terminal,
            label: 'Info de bash',
            enabled: rootfsReady,
            onTap: onBash,
          ),
          _MenuItem(
            icon: Icons.cleaning_services,
            label: 'Limpiar pantalla',
            onTap: onClearOutput,
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: enabled ? Colors.white70 : Colors.white24,
        size: 22,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: enabled ? Colors.white : Colors.white30,
          fontSize: 14,
        ),
      ),
      onTap: enabled ? onTap : null,
      dense: true,
    );
  }
}

// ── Chip de atajo ─────────────────────────────────────────────
class _ShortcutChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ShortcutChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          border: Border.all(color: const Color(0xFF00D4FF30)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF00D4FF),
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ── Modelos de datos ──────────────────────────────────────────
enum LineType { output, command, info, warning, error, success }

class _OutputLine {
  final String text;
  final LineType type;
  const _OutputLine(this.text, this.type);

  Color get color {
    switch (type) {
      case LineType.command: return const Color(0xFF00D4FF);
      case LineType.info:    return Colors.white54;
      case LineType.warning: return Colors.orange;
      case LineType.error:   return Colors.redAccent;
      case LineType.success: return Colors.greenAccent;
      case LineType.output:  return Colors.white;
    }
  }
}
