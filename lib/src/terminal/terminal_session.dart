import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import '../container/container_manager.dart';
import '../ssh/ssh_host.dart';
import 'terminal_recorder.dart';

/// Una sesión de terminal independiente (una pestaña): su propio Terminal,
/// Controller y PTY. El PTY se arranca de forma diferida (cuando el
/// TerminalView ya conoce su tamaño) vía start().
class TerminalSession {
  final String name;
  final Terminal terminal = Terminal(maxLines: 10000);
  final TerminalController controller = TerminalController();
  /// Scroll del TerminalView de esta sesión. Vive en el objeto sesión (no
  /// en un mapa por índice) por la misma razón que sourceHost: si se
  /// cierra una pestaña intermedia los índices se desplazan y el dato debe
  /// viajar con su sesión. El overlay de selección lo usa para el
  /// auto-scroll al arrastrar las asas, y TerminalView lo recibe como
  /// scrollController para que ambos compartan el mismo Scrollable.
  final ScrollController scrollController = ScrollController();
  final ContainerManager _manager = ContainerManager();
  final TerminalRecorder recorder;
  /// Si no es null, se ejecuta ESTE comando en vez del shell por defecto
  /// (p.ej. "ssh -p 22 usuario@host"). El PTY es igual de real en ambos
  /// casos: ssh lo detecta como terminal interactivo y funciona igual que
  /// si se escribiera a mano.
  final String? customCommand;
  /// Si esta sesion viene de conectar a un SshHost, se guarda aqui -- para
  /// poder ofrecer "abrir SFTP de este host" desde la propia terminal.
  /// En el objeto sesion, no en un mapa por indice: sobrevive si se
  /// cierran otras pestanas y los indices se desplazan.
  final SshHost? sourceHost;

  Pty? _pty;
  bool _started = false;
  bool get isStarted => _started;

  TerminalSession(this.name, {this.customCommand, this.sourceHost}) : recorder = TerminalRecorder(label: name);

  /// Arranca el shell con el tamaño dado. Idempotente.
  void start({required int columns, required int rows}) {
    if (_started) return;
    _started = true;

    final pty = customCommand != null
        ? _manager.startProcess(
            customCommand!,
            rows: rows > 0 ? rows : 24,
            columns: columns > 0 ? columns : 80,
          )
        : _manager.startShell(
            rows: rows > 0 ? rows : 24,
            columns: columns > 0 ? columns : 80,
          );
    _pty = pty;

    unawaited(recorder.startSession(_manager.rootfsPath!));

    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen((data) {
      terminal.write(data);
      recorder.feed(data);
    });

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
    unawaited(recorder.dispose());
    scrollController.dispose();
    controller.dispose();
  }
}
