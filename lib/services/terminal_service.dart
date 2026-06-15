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
    TerminalLine('Linux Container v9.5 - Terminal'),
    TerminalLine('Escribe comandos. Icono para cambiar modo Linux/Shell.'),
    TerminalLine(''),
  ];
  bool _running = false;
  bool _linuxMode = false;

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
      // SIEMPRE usar el mismo code path que setup: proot_service.runCommand
      // Esto unifica la ejecucion y evita inconsistencias
      if (proot.initialized || proot.hasBionic) {
        // Usar runCommand que ya maneja linker64 + workingDirectory correctamente
        output = await proot.runCommand(command, timeout: const Duration(seconds: 30));
      } else {
        // Antes de setup: ejecucion minima sin rootfs
        output = await _runFallback(command);
      }
    } catch (e) {
      output = '[Error] $e';
    }

    if (output.trim().isNotEmpty) {
      for (final line in output.split('\n')) {
        _lines.add(TerminalLine(line, isInput: false, isError: line.contains('rror') || line.contains('denied')));
      }
    } else {
      _lines.add(TerminalLine('[Comando ejecutado sin output]'));
    }

    _running = false;
    notifyListeners();
  }

  /// Fallback para cuando no hay rootfs ni bionic (app recien instalada)
  Future<String> _runFallback(String command) async {
    try {
      final r = await Process.run('/system/bin/sh', ['-c', command],
        environment: {'PATH': '/system/bin:/system/xbin', 'HOME': '/data/local/tmp', 'TERM': 'xterm'},
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
    notifyListeners();
  }
}
