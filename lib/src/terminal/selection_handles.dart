// lib/src/terminal/selection_handles.dart
//
// Asas de selección arrastrables, estilo Termius/selección nativa de
// Android: dos círculos en los extremos de la selección que se pueden
// arrastrar por separado para ajustar el principio o el final, celda a
// celda, sin tener que rehacer el gesto desde cero.
//
// Por que hace falta esto y no basta con lo que trae xterm de serie:
// TerminalView no expone ningun parametro de seleccion (ni onSelectionChanged,
// ni handles, nada) — el gesto que arranca la seleccion es una caja negra
// interna del paquete. Lo unico que se puede hacer desde fuera es LEER el
// resultado (TerminalController.selection) y, gracias a setSelection(),
// FIJARLO a mano. Este widget usa exactamente eso: no toca ni reemplaza el
// gesto que ya arranca la seleccion, solo anade una forma de AJUSTARLA
// despues, con precision de celda.
//
// Geometria: el ancho/alto real de una celda se lee de
// TerminalViewState.globalCursorRect (la medida que usa el propio paquete
// para pintar el cursor), no se calcula a ojo desde el tamano de fuente.
// Combinado con Buffer.cursorX/cursorY (posicion del cursor relativa al
// viewport) se puede despejar el origen exacto de la celda (0,0) del
// viewport en coordenadas LOCALES del propio TerminalView.
//
// Esta es la unica pieza de esta noche que no se ha podido probar contra
// el render real — necesita verificacion en el dispositivo.

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class SelectionHandlesOverlay extends StatefulWidget {
  final Terminal terminal;
  final TerminalController controller;
  final GlobalKey<TerminalViewState> viewKey;

  const SelectionHandlesOverlay({
    super.key,
    required this.terminal,
    required this.controller,
    required this.viewKey,
  });

  @override
  State<SelectionHandlesOverlay> createState() => _SelectionHandlesOverlayState();
}

class _SelectionHandlesOverlayState extends State<SelectionHandlesOverlay> {
  // Capturados al empezar CADA arrastre — el otro extremo se reconstruye
  // fresco en cada frame porque setSelection() toma posesion de los
  // CellAnchor que recibe y los libera al cambiar la seleccion; reutilizar
  // uno viejo no es seguro.
  int? _fixedX;
  int? _fixedY;
  bool _draggingStart = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Tamano de celda + origen del viewport, en coordenadas LOCALES del
  /// propio TerminalView (no globales de pantalla: los handles viven en el
  /// mismo Stack que el TerminalView, asi que se posicionan en su mismo
  /// sistema de coordenadas).
  ({double cellW, double cellH, double originX, double originY})? _metrics() {
    final state = widget.viewKey.currentState;
    final ctx = widget.viewKey.currentContext;
    if (state == null || ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;

    final globalCursor = state.globalCursorRect;
    final localTopLeft = box.localToGlobal(Offset.zero);
    final localCursor = globalCursor.shift(-localTopLeft);

    final cellW = localCursor.width;
    final cellH = localCursor.height;
    if (cellW <= 0 || cellH <= 0) return null;

    final buf = widget.terminal.buffer;
    final originX = localCursor.left - (buf.cursorX * cellW);
    final originY = localCursor.top - (buf.cursorY * cellH);

    return (cellW: cellW, cellH: cellH, originX: originX, originY: originY);
  }

  /// Fila absoluta del buffer (incluye scrollback) del primer renglon
  /// visible del viewport ahora mismo.
  int _viewportTopAbsolute() {
    final buf = widget.terminal.buffer;
    return buf.height - buf.viewHeight - buf.scrollBack;
  }

  /// Convierte una fila absoluta del buffer en posicion vertical LOCAL
  /// dentro del viewport, o null si esta fuera de lo que se ve ahora mismo
  /// (la seleccion sigue viva en el buffer aunque hayas hecho scroll y ya
  /// no se vea; el asa correspondiente simplemente no se dibuja).
  double? _localY(int absoluteRow, num cellH, num originY) {
    final viewportRow = absoluteRow - _viewportTopAbsolute();
    if (viewportRow < 0 || viewportRow >= widget.terminal.buffer.viewHeight) {
      return null;
    }
    return originY + viewportRow * cellH;
  }

  void _startDrag(bool isStartHandle) {
    final sel = widget.controller.selection;
    if (sel == null) return;
    final fixed = isStartHandle ? sel.end : sel.begin;
    _fixedX = fixed.x;
    _fixedY = fixed.y;
    _draggingStart = isStartHandle;
  }

  void _updateDrag(DragUpdateDetails details) {
    final m = _metrics();
    if (m == null || _fixedX == null || _fixedY == null) return;

    final box = widget.viewKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(details.globalPosition);

    final col = ((local.dx - m.originX) / m.cellW).round().clamp(
        0, widget.terminal.buffer.viewWidth - 1);
    final viewportRow = ((local.dy - m.originY) / m.cellH).round();
    final absoluteRow = (viewportRow + _viewportTopAbsolute()).clamp(
        0, widget.terminal.buffer.height - 1);

    final buf = widget.terminal.buffer;
    final movingAnchor = buf.createAnchor(col, absoluteRow);
    final fixedAnchor = buf.createAnchor(_fixedX!, _fixedY!);

    if (_draggingStart) {
      widget.controller.setSelection(movingAnchor, fixedAnchor);
    } else {
      widget.controller.setSelection(fixedAnchor, movingAnchor);
    }
  }

  void _endDrag() {
    _fixedX = null;
    _fixedY = null;
  }

  Widget _handle({required bool isStart}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _startDrag(isStart),
      onPanUpdate: _updateDrag,
      onPanEnd: (_) => _endDrag(),
      child: Container(
        width: 28,
        height: 28,
        alignment: isStart ? Alignment.topCenter : Alignment.bottomCenter,
        child: CustomPaint(
          size: const Size(28, 14),
          painter: _TeardropPainter(pointsUp: isStart),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.controller.selection;
    if (sel == null) return const SizedBox.shrink();

    final m = _metrics();
    if (m == null) return const SizedBox.shrink();

    final startY = _localY(sel.begin.y, m.cellH, m.originY);
    final endY = _localY(sel.end.y, m.cellH, m.originY);

    final children = <Widget>[];

    if (startY != null) {
      final x = m.originX + sel.begin.x * m.cellW;
      children.add(Positioned(
        left: x - 14,
        top: startY - 28,
        child: _handle(isStart: true),
      ));
    }
    if (endY != null) {
      final x = m.originX + (sel.end.x + 1) * m.cellW;
      children.add(Positioned(
        left: x - 14,
        top: endY + m.cellH,
        child: _handle(isStart: false),
      ));
    }

    return Stack(children: children);
  }
}

/// Forma de "gota" clasica de las asas de seleccion nativas: un circulo con
/// un pico hacia el texto. pointsUp=true para el asa de inicio (pico hacia
/// arriba, hacia la linea de texto que tiene encima), false para la de
/// final (pico hacia arriba tambien, porque el circulo va DEBAJO del
/// renglon en ambos casos — es el estandar Android/iOS).
class _TeardropPainter extends CustomPainter {
  final bool pointsUp;
  const _TeardropPainter({required this.pointsUp});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.greenAccent.shade400;
    final cx = size.width / 2;
    final r = size.width / 2;
    canvas.drawCircle(Offset(cx, size.height - r), r, paint);
    final path = Path()
      ..moveTo(cx - r * 0.5, size.height - r)
      ..lineTo(cx, size.height - r * 2.1)
      ..lineTo(cx + r * 0.5, size.height - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TeardropPainter oldDelegate) =>
      oldDelegate.pointsUp != pointsUp;
}
