import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [];
  bool _running = false;
  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  final StringBuffer _currentOutput = StringBuffer();

  List<TerminalLine> get lines => List.unmodifiable(_lines);
  bool get running => _running;
  String get currentOutput => _currentOutput.toString();

  void addLine(String text, {TerminalLineType type = TerminalLineType.output}) {
    _lines.add(TerminalLine(text: text, type: type));
    _currentOutput.writeln(text);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _currentOutput.clear();
    notifyListeners();
  }

  Future<void> execute(String command, {String? workingDir}) async {
    if (_running) return;

    _running = true;
    addLine('\$ $command', type: TerminalLineType.command);
    notifyListeners();

    try {
      _process = await Process.start(
        '/bin/sh',
        ['-c', command],
        workingDirectory: workingDir,
        environment: {
          'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
          'TERM': 'xterm-256color',
        },
      );

      _stdoutSub = _process!.stdout
          .transform(utf8.decoder)
          .listen((data) {
        addLine(data, type: TerminalLineType.output);
      });

      _stderrSub = _process!.stderr
          .transform(utf8.decoder)
          .listen((data) {
        addLine(data, type: TerminalLineType.error);
      });

      await _process!.exitCode;
    } catch (e) {
      addLine('[Error] $e', type: TerminalLineType.error);
    } finally {
      _running = false;
      _stdoutSub?.cancel();
      _stderrSub?.cancel();
      _process = null;
      if (_lines.isNotEmpty && _lines.last.text != '') {
        addLine('', type: TerminalLineType.output);
      }
      notifyListeners();
    }
  }

  void cancel() {
    _process?.kill();
    _running = false;
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

class TerminalLine {
  final String text;
  final TerminalLineType type;

  TerminalLine({required this.text, required this.type});
}

enum TerminalLineType { command, output, error }
