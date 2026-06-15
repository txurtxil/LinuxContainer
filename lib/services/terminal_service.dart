import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'proot_service.dart';

class TerminalLine {
  final String text;
  final bool isInput;
  final bool isError;
  TerminalLine(this.text, {this.isInput = false, this.isError = false});
}

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [
    TerminalLine('Linux Container v9.5f - Terminal'),
    TerminalLine('Icono para cambiar modo Linux/Shell.'),
    TerminalLine(''),
  ];
  bool _running = false;
  bool _linuxMode = true;

  List<TerminalLine> get lines => _lines;
  bool get running => _running;
  bool get linuxMode => _linuxMode;

  void toggleMode() {
    _linuxMode = !_linuxMode;
    _lines.add(TerminalLine('[Modo: ${_linuxMode ? "Linux Container" : "Shell Local"}]'));
    notifyListeners();
  }

  Future<void> executeCommand(String command) async {
    if (command.trim().isEmpty) {
      _lines.add(TerminalLine(''));
      notifyListeners();
      return;
    }

    _running = true;
    _lines.add(TerminalLine('\$ $command', isInput: true));
    notifyListeners();

    final proot = ProotService();
    String output;

    try {
      if (proot.initialized || proot.hasBionic) {
        output = await proot.runCommand(command, timeout: const Duration(seconds: 30));
      } else {
        output = await _runFallback(command);
      }
    } catch (e) {
      output = '[Error] $e';
    }

    if (output.trim().isNotEmpty) {
      for (final line in output.split('\n')) {
        _lines.add(TerminalLine(
          line,
          isInput: false,
          isError: line.toLowerCase().contains('error') || 
                   line.toLowerCase().contains('denied') ||
                   line.toLowerCase().contains('not found'),
        ));
      }
    } else {
      _lines.add(TerminalLine(''));
    }

    _running = false;
    notifyListeners();
  }

  /// Fallback para cuando no hay rootfs ni bionic (app recien instalada)
  Future<String> _runFallback(String command) async {
    try {
      final r = await Process.run('/system/bin/sh', ['-c', command],
        environment: {
          'PATH': '/system/bin:/system/xbin',
          'HOME': '/data/local/tmp',
          'TERM': 'xterm',
        },
        workingDirectory: '/data/local/tmp',
      ).timeout(const Duration(seconds: 15));
      final out = (r.stdout as String).trim();
      final err = (r.stderr as String).trim();
      return err.isNotEmpty ? '$out\n$err' : out;
    } catch (e) {
      return '[Error] $e';
    }
  }

  void clear() {
    _lines.clear();
    _lines.add(TerminalLine('Linux Container v9.5f - Terminal'));
    _lines.add(TerminalLine(''));
    notifyListeners();
  }
}
