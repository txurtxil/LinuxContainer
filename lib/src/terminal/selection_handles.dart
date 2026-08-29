/ lib/src/terminal/selection_handles.dart
//
// Asas de selección arrastrables + barra 
// flotante Copiar/Pegar/Todo, estilo selección 
// nativa de Android.
//
// v3: corregidos 3 errores de tipos que solo 
// salen al compilar de verdad (Dart .clamp() 
// SIEMPRE devuelve num, nunca el tipo original 
// int/double — hace falta .toInt()/.toDouble() 
// explícito después). No tengo compilador aquí; 
// si queda alguno más, el próximo `flutter 
// analyze` lo dirá.
//
// El diagnóstico visible (banner rojo si 
// _metrics() falla) se mantiene. El boton verde 
// "Copiar" antiguo de terminal_view.dart sigue 
// sin tocar, a proposito, como red de seguridad 
// mientras esto se confirma.
import 'package:flutter/material.dart'; import 
'package:xterm/xterm.dart'; class 
SelectionHandlesOverlay extends StatefulWidget {
  final Terminal terminal; final 
  TerminalController controller; final 
  GlobalKey<TerminalViewState> viewKey; final 
  VoidCallback onCopy; final VoidCallback 
  onPaste; final VoidCallback onSelectAll; const 
  SelectionHandlesOverlay({
    super.key, required this.terminal, required 
    this.controller, required this.viewKey, 
    required this.onCopy, required this.onPaste, 
    required this.onSelectAll,
  });
  @override State<SelectionHandlesOverlay> 
  createState() => 
  _SelectionHandlesOverlayState();
}
class _SelectionHandlesOverlayState extends 
State<SelectionHandlesOverlay> {
  int? _fixedX; int? _fixedY; bool _draggingStart 
  = false; @override void initState() {
    super.initState(); 
    widget.controller.addListener(_onChange);
  }
  // FIX: sin esto, cambiar de pestaña (o 
  // conectar a un host SSH nuevo, que abre otra 
  // sesión) deja la escucha enganchada al 
  // controller VIEJO para siempre — Flutter 
  // reutiliza este State en vez de crear uno 
  // nuevo al cambiar de sesión, así que sin este 
  // override nadie avisa cuando el controller 
  // cambia de identidad.
  @override void didUpdateWidget(covariant 
  SelectionHandlesOverlay oldWidget) {
    super.didUpdateWidget(oldWidget); if 
    (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange); 
      widget.controller.addListener(_onChange); 
      _onChange(); // lectura fresca ya mismo, no 
      solo en el próximo cambio
    }
  }
  @override void dispose() { 
    widget.controller.removeListener(_onChange); 
    super.dispose();
  }
  void _onChange() { if (mounted) setState(() 
    {});
  }
  // v4: el cálculo anterior deducía el tamaño de 
  // celda a partir del cursor parpadeante 
  // (globalCursorRect + buf.cursorX/cursorY). 
  // Eso asumía que la posición reportada del 
  // cursor siempre corresponde exactamente a la 
  // fila que yo creía — y en la práctica las 
  // asas aparecían muchas filas por debajo de 
  // donde debían, o no aparecían en absoluto. 
  // Nueva estrategia, sin esa suposición: el 
  // tamaño de UNA celda es, sencillamente, el 
  // tamaño total del widget dividido entre 
  // columnas y filas — buf.viewWidth y 
  // buf.viewHeight, los mismos valores que ya se 
  // usan sin problema en _visibleText() y 
  // _selectAll(). El origen es (0,0) en 
  // coordenadas LOCALES del propio TerminalView, 
  // asumiendo que no tiene padding interno (no 
  // se configuró ninguno en este proyecto).
  (({double cellW, double cellH, double originX, 
  double originY})?, String?) _metrics() {
    final ctx = widget.viewKey.currentContext; if 
    (ctx == null) return (null, 
    'viewKey.currentContext es null'); final box 
    = ctx.findRenderObject(); if (box is! 
    RenderBox) return (null, 'findRenderObject() 
    no es un RenderBox (${box.runtimeType})'); if 
    (!box.hasSize) return (null, 'el RenderBox 
    aun no tiene tamano (hasSize=false)'); final 
    buf = widget.terminal.buffer; final viewW = 
    buf.viewWidth; final viewH = buf.viewHeight; 
    if (viewW <= 0 || viewH <= 0) {
      return (null, 'viewWidth/viewHeight 
      inválidos: $viewW x $viewH');
    }
    final cellW = box.size.width / viewW; final 
    cellH = box.size.height / viewH; if (cellW <= 
    0 || cellH <= 0) {
      return (null, 'celda inválida: cellW=$cellW 
      cellH=$cellH (box=${box.size})');
    }
    return ((cellW: cellW, cellH: cellH, originX: 
    0.0, originY: 0.0), null);
  }
  int _viewportTopAbsolute() { final buf = 
    widget.terminal.buffer; return buf.height - 
    buf.viewHeight - buf.scrollBack;
  }
  // FIX: eran "num cellH, num originY" — Dart no 
  // puede devolver un num como double aunque en 
  // la practica siempre lo sea. Tipado 
  // explicito.
  double? _localY(int absoluteRow, double cellH, 
  double originY) {
    final viewportRow = absoluteRow - 
    _viewportTopAbsolute(); if (viewportRow < 0 
    || viewportRow >= 
    widget.terminal.buffer.viewHeight) { return 
      null;
    }
    return originY + viewportRow * cellH;
  }
  void _startDrag(bool isStartHandle) { final sel 
    = widget.controller.selection; if (sel == 
    null) return; final fixed = isStartHandle ? 
    sel.end : sel.begin; _fixedX = fixed.x; 
    _fixedY = fixed.y; _draggingStart = 
    isStartHandle;
  }
  void _updateDrag(DragUpdateDetails details) { 
    final (m, _) = _metrics(); if (m == null || 
    _fixedX == null || _fixedY == null) return; 
    final box = 
    widget.viewKey.currentContext?.findRenderObject(); 
    if (box is! RenderBox) return; final local = 
    box.globalToLocal(details.globalPosition);
    // FIX: .clamp() en Dart siempre devuelve 
    // num, nunca int, aunque el receptor sea 
    // int. buf.createAnchor() exige int de 
    // verdad -> .toInt().
    final col = ((local.dx - m.originX) / 
    m.cellW)
        .round() .clamp(0, 
        widget.terminal.buffer.viewWidth - 1) 
        .toInt();
    final viewportRow = ((local.dy - m.originY) / 
    m.cellH).round(); final absoluteRow = 
    (viewportRow + _viewportTopAbsolute())
        .clamp(0, widget.terminal.buffer.height - 
        1) .toInt();
    final buf = widget.terminal.buffer; final 
    movingAnchor = buf.createAnchor(col, 
    absoluteRow); final fixedAnchor = 
    buf.createAnchor(_fixedX!, _fixedY!); if 
    (_draggingStart) {
      widget.controller.setSelection(movingAnchor, 
      fixedAnchor);
    } else {
      widget.controller.setSelection(fixedAnchor, 
      movingAnchor);
    }
  }
  void _endDrag() { _fixedX = null; _fixedY = 
    null;
  }
  Widget _handle({required bool isStart}) { 
    return GestureDetector(
      behavior: HitTestBehavior.opaque, 
      onPanStart: (_) => _startDrag(isStart), 
      onPanUpdate: _updateDrag, onPanEnd: (_) => 
      _endDrag(), child: Container(
        width: 28, height: 28, alignment: isStart 
        ? Alignment.topCenter : 
        Alignment.bottomCenter, child: 
        CustomPaint(
          size: const Size(28, 14), painter: 
          const _TeardropPainter(),
        ), ), );
  }
  Widget _toolbarButton(String label, IconData 
  icon, VoidCallback onTap) {
    return InkWell( onTap: onTap, child: Padding( 
        padding: const 
        EdgeInsets.symmetric(horizontal: 12, 
        vertical: 8), child: Row(
          mainAxisSize: MainAxisSize.min, 
          children: [
            Icon(icon, size: 16, color: 
            Colors.white), const SizedBox(width: 
            5), Text(label, style: const 
            TextStyle(color: Colors.white, 
            fontSize: 13)),
          ], ), ), );
  }
  Widget _toolbar() { return Material( color: 
      const Color(0xFF3A3A3C), borderRadius: 
      BorderRadius.circular(8), elevation: 6, 
      child: Row(
        mainAxisSize: MainAxisSize.min, children: 
        [
          _toolbarButton('Copiar', Icons.copy, 
          widget.onCopy), Container(width: 1, 
          height: 20, color: Colors.white24), 
          _toolbarButton('Pegar', 
          Icons.content_paste, widget.onPaste), 
          Container(width: 1, height: 20, color: 
          Colors.white24), _toolbarButton('Todo', 
          Icons.select_all, widget.onSelectAll),
        ], ), );
  }
  @override Widget build(BuildContext context) { 
    final sel = widget.controller.selection; if 
    (sel == null) return const SizedBox.shrink(); 
    final (m, reason) = _metrics(); if (m == 
    null) {
      return Positioned( left: 8, bottom: 8, 
        right: 8, child: Material(
          color: Colors.red.shade900, 
          borderRadius: BorderRadius.circular(6), 
          child: Padding(
            padding: const EdgeInsets.all(8), 
            child: Text(
              'DEBUG asas: $reason', style: const 
              TextStyle(color: Colors.white, 
              fontSize: 11),
            ), ), ), );
    }
    final startY = _localY(sel.begin.y, m.cellH, 
    m.originY); final endY = _localY(sel.end.y, 
    m.cellH, m.originY); final children = 
    <Widget>[]; if (startY != null) {
      final x = m.originX + sel.begin.x * 
      m.cellW; children.add(Positioned(
        left: x - 14, top: startY - 28, child: 
        _handle(isStart: true),
      ));
    }
    if (endY != null) { final x = m.originX + 
      (sel.end.x + 1) * m.cellW; 
      children.add(Positioned(
        left: x - 14, top: endY + m.cellH, child: 
        _handle(isStart: false),
      ));
    }
    if (startY != null || endY != null) { const 
      toolbarHeight = 40.0;
      // FIX: mismo problema de .clamp() -> num. 
      // Aqui hace falta double (Positioned.left 
      // lo exige), no int.
      final double toolbarLeftRaw = m.originX + 
      sel.begin.x * m.cellW; final double 
      toolbarLeft = toolbarLeftRaw < 0 ? 0.0 : 
      toolbarLeftRaw; double toolbarTop; if 
      (startY != null && startY - toolbarHeight - 
      4 > 0) {
        toolbarTop = startY - toolbarHeight - 4;
      } else if (endY != null) {
        toolbarTop = endY + m.cellH + 32;
      } else {
        toolbarTop = (startY ?? 0) + 32;
      }
      children.add(Positioned( left: toolbarLeft, 
        top: toolbarTop, child: _toolbar(),
      ));
    }
    return Stack(children: children);
  }
}
class _TeardropPainter extends CustomPainter { 
  const _TeardropPainter(); @override void 
  paint(Canvas canvas, Size size) {
    final paint = Paint()..color = 
    Colors.greenAccent.shade400; final cx = 
    size.width / 2; final r = size.width / 2; 
    canvas.drawCircle(Offset(cx, size.height - 
    r), r, paint); final path = Path()
      ..moveTo(cx - r * 0.5, size.height - r) 
      ..lineTo(cx, size.height - r * 2.1) 
      ..lineTo(cx + r * 0.5, size.height - r) 
      ..close();
    canvas.drawPath(path, paint);
  }
  @override bool shouldRepaint(covariant 
  _TeardropPainter oldDelegate) => false;
}
