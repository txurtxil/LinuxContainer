import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Barra de teclas especiales. Orden: menú ⋮, controles directos, navegación,
/// símbolos, fuente, y a la derecha Esc/Ctrl/Tab (Ctrl sticky para flechas).
class TerminalKeybar extends StatefulWidget {
  final Terminal terminal;
  final VoidCallback? onFontIncrease;
  final VoidCallback? onFontDecrease;
  final VoidCallback? onMenu;

  const TerminalKeybar({
    super.key,
    required this.terminal,
    this.onFontIncrease,
    this.onFontDecrease,
    this.onMenu,
  });

  @override
  State<TerminalKeybar> createState() => _TerminalKeybarState();
}

class _TerminalKeybarState extends State<TerminalKeybar> {
  bool _ctrl = false;

  void _toggleCtrl() => setState(() => _ctrl = !_ctrl);
  void _clearCtrl() {
    if (_ctrl) setState(() => _ctrl = false);
  }

  void _ctrlChar(String letter) => widget.terminal.charInput(letter.codeUnitAt(0), ctrl: true);

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(key, ctrl: _ctrl);
    _clearCtrl();
  }

  void _sendChar(String ch) {
    if (_ctrl) {
      widget.terminal.charInput(ch.codeUnitAt(0), ctrl: true);
      _clearCtrl();
    } else {
      widget.terminal.textInput(ch);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: const Color(0xFF1A1A1A),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          // Menú al principio del todo (izquierda)
          _key('⋮', onTap: () => widget.onMenu?.call(), highlight: true),
          _sep(),
          // Controles directos
          _key('^C', onTap: () => _ctrlChar('c'), accent: true),
          _key('^X', onTap: () => _ctrlChar('x'), accent: true),
          _key('^Z', onTap: () => _ctrlChar('z'), accent: true),
          _key('^R', onTap: () => _ctrlChar('r'), accent: true),
          _sep(),
          // Navegación
          _key('↑', onTap: () => _sendKey(TerminalKey.arrowUp)),
          _key('↓', onTap: () => _sendKey(TerminalKey.arrowDown)),
          _key('←', onTap: () => _sendKey(TerminalKey.arrowLeft)),
          // Esc y Ctrl reubicados a la derecha de la flecha izquierda
          _key('Esc', onTap: () => _sendKey(TerminalKey.escape)),
          _key('Ctrl', onTap: _toggleCtrl, active: _ctrl),
          _key('→', onTap: () => _sendKey(TerminalKey.arrowRight)),
          _key('Tab', onTap: () => _sendKey(TerminalKey.tab)),
          _key('Home', onTap: () => _sendKey(TerminalKey.home)),
          _key('End', onTap: () => _sendKey(TerminalKey.end)),
          _key('PgUp', onTap: () => _sendKey(TerminalKey.pageUp)),
          _key('PgDn', onTap: () => _sendKey(TerminalKey.pageDown)),
          _sep(),
          // Símbolos
          _key('|', onTap: () => _sendChar('|')),
          _key('/', onTap: () => _sendChar('/')),
          _key('-', onTap: () => _sendChar('-')),
          _key('~', onTap: () => _sendChar('~')),
          _sep(),
          // Fuente
          _key('A−', onTap: () => widget.onFontDecrease?.call(), highlight: true),
          _key('A+', onTap: () => widget.onFontIncrease?.call(), highlight: true),
        ],
      ),
    );
  }

  Widget _sep() => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        color: Colors.white24,
      );

  Widget _key(String label, {required VoidCallback onTap, bool accent = false, bool highlight = false, bool active = false}) {
    final Color bg = active
        ? Colors.green.shade700
        : highlight
            ? const Color(0xFF1E4620)
            : accent
                ? const Color(0xFF2A3F5F)
                : const Color(0xFF333333);
    final Color fg = active
        ? Colors.white
        : highlight
            ? Colors.lightGreenAccent
            : accent
                ? Colors.lightBlueAccent
                : Colors.greenAccent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Text(label, style: TextStyle(color: fg, fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
