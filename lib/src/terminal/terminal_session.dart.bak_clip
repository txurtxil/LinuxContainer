import 'dart:convert';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import '../container/container_manager.dart';

/// Una sesión de terminal independiente (una pestaña): su propio Terminal,
/// Controller y PTY. El PTY se arranca de forma diferida (cuando el
/// TerminalView ya conoce su tamaño) vía start().
class TerminalSession {
  final String name;
  final Terminal terminal = Terminal(maxLines: 10000);
  final TerminalController controller = TerminalController();
  final ContainerManager _manager = ContainerManager();

  Pty? _pty;
  bool _started = false;
  bool get isStarted => _started;

  TerminalSession(this.name);

  /// Arranca el shell con el tamaño dado. Idempotente.
  void start({required int columns, required int rows}) {
    if (_started) return;
    _started = true;

    final pty = _manager.startShell(
      rows: rows > 0 ? rows : 24,
      columns: columns > 0 ? columns : 80,
    );
    _pty = pty;

    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen(terminal.write);

    terminal.onOutput = (data) {
      pty.write(const Utf8Encoder().convert(data));
    };

    terminal.onResize = (w, h, pw, ph) {
      pty.resize(h, w);
    };

    pty.exitCode.then((code) {
      terminal.write('\r\n[sesión finalizada, código $code]\r\n');
    });
  }

  /// Reinicia el shell de esta sesión (mata el PTY y arranca otro).
  void restart({required int columns, required int rows}) {
    _pty?.kill();
    _started = false;
    terminal.write('\r\n\x1b[1;33m[reiniciando shell...]\x1b[0m\r\n');
    start(columns: columns, rows: rows);
  }

  void dispose() {
    _pty?.kill();
    _pty = null;
    controller.dispose();
  }
}
