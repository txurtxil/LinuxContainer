import 'package:flutter/foundation.dart';

class TerminalService extends ChangeNotifier {
  final List<TerminalLine> _lines = [];
  bool _running = false;

  List<TerminalLine> get lines => List.unmodifiable(_lines);
  bool get running => _running;

  void addLine(String text, {TerminalLineType type = TerminalLineType.output}) {
    _lines.add(TerminalLine(text: text, type: type));
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  void cancel() {
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class TerminalLine {
  final String text;
  final TerminalLineType type;
  TerminalLine({required this.text, required this.type});
}

enum TerminalLineType { command, output, error }
