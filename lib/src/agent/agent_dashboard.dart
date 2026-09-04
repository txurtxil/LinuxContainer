// lib/src/agent/agent_dashboard.dart — v8.0
// Agrega: Boton de estado del entorno IA en Ajustes
//         Reloj de arena durante setup -> Check verde cuando listo

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_services.dart';
import 'agent_chat.dart';
import 'prompt_templates.dart';
import 'ssh_connections.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const ok = Color(0xFF34C759);
  static const off = Color(0xFF6B6B70);
  static const err = Color(0xFFFF453A);
  static const accent = Color(0xFF5E9BD6);
  static const warn = Color(0xFFFF9F0A);
}

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35);

class AgentDashboard extends StatefulWidget {
  final VoidCallback? onClose;
  const AgentDashboard({super.key, this.onClose});

  @override
  State<AgentDashboard> createState() => _AgentDashboardState();
}

class _AgentDashboardState extends State<AgentDashboard> {
  final _svc = AgentServices();
  final _ctrl = AgentController();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _mpPrompt = TextEditingController(
      text: 'Explica en dos frases que es un agujero negro.');

  Timer? _healthTimer;
  Timer? _bootPollTimer;
  bool _agentUp = false;
  String _selSource = 'gpu_local';

  @override
  void initState() {
    super.initState();
    _ctrl.ensureLoaded().then((_) {
      if (mounted) {
        setState(() {});
        _scrollToBottom();
      }
    });
    _svc.loadModelConfig().then((_) async {
      if (mounted) {
        setState(() => _selSource = _svc.sourceId);
        await _svc.scanMpModels();
        await _svc.syncMpStatus();
        setState(() {});
        _pollHealth();
      }
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _pollHealth();
    });
    _healthTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _pollHealth());
    _svc.agentStarting.addListener(_onSvc);
    _svc.agentFailed.addListener(_onSvc);
    _svc.envReady.addListener(_onSvc);
    _svc.envChecking.addListener(_onSvc);
    _svc.envSetupRunning.addListener(_onSvc);
    _svc.listenMpEvents((e) {
      if (mounted) {
        setState(() => _svc.handleMpEvent(e));
      }
    });
    // Verificar entorno IA al iniciar (silencioso)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _svc.checkAgentEnv();
    });
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _bootPollTimer?.cancel();
    _svc.agentStarting.removeListener(_onSvc);
    _svc.agentFailed.removeListener(_onSvc);
    _svc.envReady.removeListener(_onSvc);
    _svc.envChecking.removeListener(_onSvc);
    _svc.envSetupRunning.removeListener(_onSvc);
    _svc.cancelMpEvents();
    _input.dispose();
    _mpPrompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSvc() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _pollHealth() async {
    final a = await AgentApi.checkHealth(_svc.agentPort);
    if (mounted) setState(() => _agentUp = a);
  }

  void _startBootPoll() {
    _bootPollTimer?.cancel();
    int ticks = 0;
    _bootPollTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      ticks++;
      await _pollHealth();
      if (_agentUp || ticks >= 12) {
        t.cancel();
        if (mounted && !_agentUp && _svc.agentLaunched) {
          _svc.agentFailed.value = true;
          _svc.agentStarting.value = false;
          _snack('El agente no respondio. Revisa los logs.');
        }
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _ctrl.running.value) return;
    if (!_agentUp) {
      _ctrl.addError(
          'El agent-server (:${_svc.agentPort}) no responde. Arrancalo primero.');
      _scrollToBottom();
      return;
    }
    _ctrl.send(
      text,
      _svc.agentPort,
      baseUrl: _svc.effectiveBaseUrl,
      model: _svc.effectiveModel,
      apiKey: _svc.effectiveApiKey,
    );
    _input.clear();
    _scrollToBottom();
  }

  void _stop() => _ctrl.stop();

  void _toggleAgent() {
    final active = _agentUp || _svc.agentLaunched;
    if (active) {
      _svc.stopAgent();
    } else {
      _svc.startAgent();
      _startBootPoll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _C.bg,
      child: Column(
        children: [
          _header(),
          Expanded(child: _chatList()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _header() {
    final agentActive = _agentUp || _svc.agentLaunched;
    final failed = _svc.agentFailed.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(
        children: [
          const Icon(Icons.smart_toy_outlined, color: _C.accent, size: 20),
          const SizedBox(width: 8),
          const Text('Agente',
              style: TextStyle(
                  color: _C.textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _svc.currentModelLabel,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _C.textLo, fontSize: 12),
            ),
          ),
          const Spacer(),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: failed
                  ? _C.err
                  : (_svc.agentStarting.value
                      ? _C.warn
                      : (agentActive ? _C.ok : _C.off)),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          if (_svc.agentStarting.value && !_agentUp)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent),
            )
          else
            IconButton(
              tooltip: agentActive ? 'Detener agente' : 'Arrancar agente',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: _toggleAgent,
              icon: Icon(
                agentActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 24,
                color: agentActive ? _C.err : _C.ok,
              ),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Logs del agente',
            onPressed: () => _showLogs('agent-server', _svc.agentLog),
            icon: Icon(
              Icons.article_outlined,
              size: 20,
              color: failed ? _C.err : _C.textLo,
            ),
          ),
          IconButton(
            tooltip: 'Ajustes',
            onPressed: _showSettingsSheet,
            icon: const Icon(Icons.tune, size: 20, color: _C.textLo),
          ),
          IconButton(
            tooltip: 'Historial',
            onPressed: _showHistorySheet,
            icon: const Icon(Icons.history, size: 20, color: _C.textLo),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: 'Terminal',
              onPressed: widget.onClose,
              icon: const Icon(Icons.terminal, size: 22, color: _C.textLo),
            ),
        ],
      ),
    );
  }

  Widget _chatList() {
    return AnimatedBuilder(
      animation: Listenable.merge([_ctrl.blocks, _ctrl.running]),
      builder: (context, _) {
        final blocks = _ctrl.blocks.value;
        final running = _ctrl.running.value;
        if (blocks.isEmpty) {
          final hint = _agentUp
              ? 'Escribe una tarea para el agente.\n\nEjemplo: "Crea un script en /root/hola.sh que imprima la fecha y ejecutalo".'
              : (_svc.agentStarting.value
                  ? 'Arrancando agent-server... espera unos segundos.'
                  : 'Pulsa el boton verde de play para arrancar el agent-server.');
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _C.off, fontSize: 13.5, height: 1.5),
              ),
            ),
          );
        }
        _scrollToBottom();
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          itemCount: blocks.length + (running ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == blocks.length) return _thinkingRow();
            return _blockWidget(blocks[i]);
          },
        );
      },
    );
  }

  Widget _thinkingRow() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent),
          ),
          SizedBox(width: 10),
          Text('razonando...', style: TextStyle(color: _C.textLo, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _blockWidget(ChatBlock b) {
    switch (b.kind) {
      case 'user':
        return Container(
          margin: const EdgeInsets.only(bottom: 16, top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _C.cardAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.border),
          ),
          child: Text(b.text,
              style: const TextStyle(color: _C.textHi, fontSize: 14, height: 1.4)),
        );

      case 'thought':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            b.text,
            style: const TextStyle(
                color: _C.textLo, fontSize: 13, height: 1.45, fontStyle: FontStyle.italic),
          ),
        );

      case 'tool':
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _C.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.terminal_rounded, size: 15, color: _C.accent),
                  const SizedBox(width: 7),
                  Text(b.toolName ?? 'tool',
                      style: const TextStyle(
                          color: _C.accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace')),
                  if (b.step != null) ...[
                    const Spacer(),
                    Text('paso ${b.step}',
                        style: const TextStyle(color: _C.off, fontSize: 11)),
                  ],
                ],
              ),
              if (b.toolArgs != null && b.toolArgs!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(b.toolArgs!, style: _mono.copyWith(color: _C.textHi)),
              ],
            ],
          ),
        );

      case 'observation':
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: _C.cardAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.border),
          ),
          child: SingleChildScrollView(
            child: Text(b.text, style: _mono.copyWith(color: _C.textLo)),
          ),
        );

      case 'final':
        return Container(
          margin: const EdgeInsets.only(bottom: 16, top: 4),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: _C.card,
            borderRadius: BorderRadius.circular(12),
            border: const Border(
                left: BorderSide(color: _C.accent, width: 3),
                top: BorderSide(color: _C.border),
                right: BorderSide(color: _C.border),
                bottom: BorderSide(color: _C.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(b.text,
                  style: const TextStyle(
                      color: _C.textHi, fontSize: 14.5, height: 1.5)),
              const SizedBox(height: 6),
              InkWell(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: b.text));
                  if (mounted) _snack('Copiado');
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_all, size: 14, color: _C.off),
                    SizedBox(width: 4),
                    Text('Copiar', style: TextStyle(color: _C.off, fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        );

      case 'error':
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF2A1D1D),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF5A2A2A)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 16, color: _C.err),
              const SizedBox(width: 8),
              Expanded(
                child: Text(b.text,
                    style: const TextStyle(
                        color: Color(0xFFE5B5B5), fontSize: 13, height: 1.4)),
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _inputBar() {
    return AnimatedBuilder(
      animation: _ctrl.running,
      builder: (context, _) {
        final running = _ctrl.running.value;
        return Container(
          decoration: const BoxDecoration(
            color: _C.bg,
            border: Border(top: BorderSide(color: _C.border)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Row(
            children: [
              IconButton(
                onPressed: running
                    ? null
                    : () async {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text;
                        if (text != null && text.isNotEmpty) {
                          _input.text = _input.text.isEmpty
                              ? text
                              : '${_input.text} $text';
                        }
                      },
                icon: const Icon(Icons.content_paste, size: 20, color: _C.off),
                tooltip: 'Pegar',
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !running,
                  minLines: 1,
                  maxLines: 6,
                  style: const TextStyle(color: _C.textHi, fontSize: 14.5),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: running ? 'Ejecutando...' : 'Tarea para el agente...',
                    hintStyle: const TextStyle(color: _C.off, fontSize: 14),
                    filled: true,
                    fillColor: _C.card,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _C.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _C.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _C.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              running
                  ? IconButton(
                      onPressed: _stop,
                      style: IconButton.styleFrom(
                        backgroundColor: _C.card,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.all(12),
                      ),
                      icon: const Icon(Icons.stop_rounded, color: _C.err),
                    )
                  : IconButton(
                      onPressed: _send,
                      style: IconButton.styleFrom(
                        backgroundColor: _C.accent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.all(12),
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white),
                    ),
            ],
          ),
        );
      },
    );
  }

  void _showLogs(String title, ValueNotifier<List<String>> log) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final logScroll = ScrollController();
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.article_outlined,
                        size: 18, color: _C.textLo),
                    const SizedBox(width: 8),
                    Text('Logs · $title',
                        style: const TextStyle(
                            color: _C.textHi,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Limpiar',
                      onPressed: () => log.value = [],
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: _C.textLo),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, size: 20, color: _C.textLo),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _C.border),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: log,
                  builder: (_, lines, __) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (logScroll.hasClients) {
                        logScroll.jumpTo(logScroll.position.maxScrollExtent);
                      }
                    });
                    if (lines.isEmpty) {
                      return const Center(
                        child: Text('Sin logs todavia.',
                            style: TextStyle(color: _C.off, fontSize: 13)),
                      );
                    }
                    return ListView.builder(
                      controller: logScroll,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(lines[i],
                            style: _mono.copyWith(color: _C.textLo)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  BOTON ENTORNO IA  (v10)
  // ═══════════════════════════════════════════════════════════════

  Widget _envStatusButton(StateSetter setS) {
    final checking = _svc.envChecking.value;
    final setupRunning = _svc.envSetupRunning.value;
    final ready = _svc.envReady.value;
    final status = _svc.envStatus.value;

    // Estados combinados
    final isWorking = checking || setupRunning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ready ? _C.ok.withValues(alpha: 0.08) : _C.cardAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ready
              ? _C.ok.withValues(alpha: 0.4)
              : isWorking
                  ? _C.accent.withValues(alpha: 0.4)
                  : _C.border,
        ),
      ),
      child: InkWell(
        onTap: isWorking
            ? null
            : () async {
                if (ready) {
                  // Ya esta listo, solo verificar de nuevo
                  await _svc.checkAgentEnv();
                  setS(() {});
                } else {
                  // Mostrar dialogo de confirmacion antes de instalar
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: _C.card,
                      title: const Text('Preparar entorno IA',
                          style: TextStyle(color: _C.textHi, fontSize: 16)),
                      content: const Text(
                        'Se instalara Python3, smolagents y las herramientas necesarias.\n\n'
                        'Requiere conexion a internet.\n'
                        'Duracion estimada: ~10 minutos.',
                        style: TextStyle(color: _C.textLo, fontSize: 13, height: 1.5),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancelar', style: TextStyle(color: _C.textLo)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Iniciar', style: TextStyle(color: _C.accent)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await _svc.setupAgentEnv();
                    setS(() {});
                  }
                }
              },
        borderRadius: BorderRadius.circular(10),
        child: Row(
          children: [
            // Icono de estado
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: ready
                    ? _C.ok.withValues(alpha: 0.15)
                    : isWorking
                        ? _C.accent.withValues(alpha: 0.15)
                        : _C.card,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isWorking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: _C.accent,
                        ),
                      )
                    : Icon(
                        ready ? Icons.check_rounded : Icons.build_outlined,
                        size: 18,
                        color: ready ? _C.ok : _C.warn,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Texto
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready
                        ? 'Entorno IA listo'
                        : isWorking
                            ? 'Preparando entorno...'
                            : 'Entorno IA no preparado',
                    style: TextStyle(
                      color: ready ? _C.ok : _C.textHi,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      status,
                      style: const TextStyle(
                        color: _C.textLo,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // Accion secundaria
            if (!isWorking)
              IconButton(
                tooltip: ready ? 'Verificar de nuevo' : 'Preparar entorno',
                onPressed: () async {
                  if (ready) {
                    await _svc.checkAgentEnv();
                  } else {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: _C.card,
                        title: const Text('Preparar entorno IA',
                            style: TextStyle(color: _C.textHi, fontSize: 16)),
                        content: const Text(
                          'Se instalara Python3, smolagents y las herramientas necesarias.\n\n'
                          'Requiere conexion a internet.\n'
                          'Duracion estimada: ~10 minutos.',
                          style: TextStyle(color: _C.textLo, fontSize: 13, height: 1.5),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancelar',
                                style: TextStyle(color: _C.textLo)),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Iniciar',
                                style: TextStyle(color: _C.accent)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await _svc.setupAgentEnv();
                    }
                  }
                  setS(() {});
                },
                icon: Icon(
                  ready ? Icons.refresh : Icons.arrow_forward,
                  size: 18,
                  color: ready ? _C.ok : _C.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showEnvSetupLogs() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final logScroll = ScrollController();
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.build_outlined, size: 18, color: _C.textLo),
                    const SizedBox(width: 8),
                    const Text('Setup Entorno IA',
                        style: TextStyle(
                            color: _C.textHi,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (_svc.envSetupRunning.value)
                      TextButton(
                        onPressed: () {
                          _svc.cancelEnvSetup();
                          Navigator.pop(ctx);
                        },
                        child: const Text('Cancelar',
                            style: TextStyle(color: _C.err, fontSize: 12)),
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, size: 20, color: _C.textLo),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _C.border),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: _svc.envLog,
                  builder: (_, lines, __) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (logScroll.hasClients) {
                        logScroll.jumpTo(logScroll.position.maxScrollExtent);
                      }
                    });
                    if (lines.isEmpty) {
                      return const Center(
                        child: Text('Esperando inicio...',
                            style: TextStyle(color: _C.off, fontSize: 13)),
                      );
                    }
                    return ListView.builder(
                      controller: logScroll,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(lines[i],
                            style: _mono.copyWith(color: _C.textLo)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSettingsSheet() {
    final baseUrlCtrl = TextEditingController(text: _svc.remoteBaseUrl);
    final modelCtrl = TextEditingController(text: _svc.remoteModel);
    final keyCtrl = TextEditingController(text: _svc.remoteApiKey);
    bool obscureKey = true;

    double temp = _svc.temp;
    double topP = _svc.topP;
    int topK = _svc.topK;
    final agentPortCtrl = TextEditingController(text: _svc.agentPort.toString());

    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setS) {
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.92,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 19, color: _C.textLo),
                          const SizedBox(width: 8),
                          const Text('Ajustes',
                              style: TextStyle(
                                  color: _C.textHi,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setS(() {
                              _svc.resetSettings();
                              temp = _svc.temp;
                              topP = _svc.topP;
                              topK = _svc.topK;
                              agentPortCtrl.text = _svc.agentPort.toString();
                            }),
                            child: const Text('Restablecer',
                                style: TextStyle(color: _C.textLo, fontSize: 12.5)),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close,
                                size: 20, color: _C.textLo),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: _C.border),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        children: [
                          // ═══ BOTON ENTORNO IA (v10) ═══
                          _envStatusButton(setS),
                          const SizedBox(height: 8),
                          // Boton para ver logs del setup
                          if (_svc.envSetupRunning.value || _svc.envLog.value.isNotEmpty)
                            Center(
                              child: TextButton.icon(
                                onPressed: _showEnvSetupLogs,
                                icon: const Icon(Icons.article_outlined,
                                    size: 14, color: _C.accent),
                                label: const Text('Ver logs del setup',
                                    style: TextStyle(color: _C.accent, fontSize: 12)),
                              ),
                            ),
                          const SizedBox(height: 18),
                          const Divider(color: _C.border),
                          const SizedBox(height: 18),

                          _cfgLabel('Fuente de inferencia'),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _sourceChip('gpu_local', 'GPU Local', setS, baseUrlCtrl, modelCtrl),
                              _sourceChip('custom', 'Personalizado', setS, baseUrlCtrl, modelCtrl),
                            ],
                          ),
                          const SizedBox(height: 18),

                          if (_selSource == 'gpu_local') ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _C.cardAlt,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _C.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.memory, size: 16, color: _C.accent),
                                      const SizedBox(width: 8),
                                      const Text('GPU Local · MediaPipe',
                                          style: TextStyle(
                                              color: _C.textHi,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600)),
                                      const Spacer(),
                                      if (_svc.mpServerRunning)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: _C.ok.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text(':8090',
                                              style: TextStyle(
                                                  color: _C.ok, fontSize: 11, fontWeight: FontWeight.w600)),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  if (_svc.mpModels.isEmpty)
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: _C.card,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: _C.border),
                                      ),
                                      child: Text(
                                        'No hay modelos en:\n${_svc.mpModelsDir ?? "(carpeta de modelos)"}\n\n'
                                        'Copia un .task (ej: gemma3-1b-it-int4.task) y recarga.',
                                        style: const TextStyle(color: _C.textLo, fontSize: 11.5, height: 1.45),
                                      ),
                                    )
                                  else
                                    Container(
                                      decoration: BoxDecoration(
                                        color: _C.card,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: _C.border),
                                      ),
                                      child: Column(
                                        children: _svc.mpModels.map((m) {
                                          final p = m.path;
                                          final name = p.split('/').last;
                                          final selected = p == _svc.mpSelectedPath;
                                          return InkWell(
                                            onTap: _svc.mpLoaded ? null : () => setS(() => _svc.mpSelectedPath = p),
                                            child: Padding(
                                              padding: const EdgeInsets.only(left: 10, right: 4, top: 6, bottom: 6),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                                    size: 16,
                                                    color: selected ? _C.accent : _C.textLo,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(name,
                                                        style: TextStyle(
                                                            color: selected ? _C.textHi : _C.textLo,
                                                            fontSize: 12),
                                                        overflow: TextOverflow.ellipsis),
                                                  ),
                                                  IconButton(
                                                    icon: const Icon(Icons.delete_outline, size: 16, color: _C.err),
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                    onPressed: () async {
                                                      await _svc.deleteMpModel(p);
                                                      if (mounted) setS(() {});
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      TextButton.icon(
                                        onPressed: () async {
                                          await _svc.importMpModel();
                                          if (mounted) setS(() {});
                                        },
                                        icon: const Icon(Icons.file_download_outlined, size: 15, color: _C.accent),
                                        label: const Text('Importar', style: TextStyle(color: _C.accent, fontSize: 12)),
                                      ),
                                      TextButton.icon(
                                        onPressed: () async {
                                          await _svc.scanMpModels();
                                          if (mounted) setS(() {});
                                        },
                                        icon: const Icon(Icons.refresh, size: 15, color: _C.textLo),
                                        label: const Text('Recargar', style: TextStyle(color: _C.textLo, fontSize: 12)),
                                      ),
                                      const Spacer(),
                                      const Text('Backend:', style: TextStyle(color: _C.textLo, fontSize: 11.5)),
                                      const SizedBox(width: 6),
                                      ToggleButtons(
                                        isSelected: [_svc.mpUseGpu, !_svc.mpUseGpu],
                                        onPressed: _svc.mpLoaded
                                            ? null
                                            : (i) => setS(() => _svc.mpUseGpu = i == 0),
                                        borderRadius: BorderRadius.circular(6),
                                        borderColor: _C.border,
                                        selectedBorderColor: _C.accent,
                                        fillColor: _C.accent,
                                        color: _C.textLo,
                                        selectedColor: Colors.white,
                                        constraints: const BoxConstraints(minHeight: 28, minWidth: 44),
                                        children: const [
                                          Text('GPU', style: TextStyle(fontSize: 11)),
                                          Text('CPU', style: TextStyle(fontSize: 11)),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: _svc.mpLoaded ? _C.card : _C.accent,
                                            foregroundColor: _svc.mpLoaded ? _C.textLo : Colors.white,
                                            padding: const EdgeInsets.symmetric(vertical: 10),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          icon: _svc.mpLoading
                                              ? const SizedBox(width: 14, height: 14,
                                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                              : Icon(_svc.mpLoaded ? Icons.check : Icons.bolt, size: 16),
                                          label: Text(_svc.mpLoaded ? 'Cargado' : 'Cargar'),
                                          onPressed: (_svc.mpLoading || _svc.mpLoaded) ? null : () async {
                                            await _svc.loadMpModel();
                                            if (mounted) setS(() {});
                                          },
                                        ),
                                      ),
                                      if (_svc.mpLoaded) ...[
                                        const SizedBox(width: 8),
                                        OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: _C.err,
                                            side: const BorderSide(color: _C.border),
                                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                                          ),
                                          onPressed: () async {
                                            await _svc.unloadMpModel();
                                            if (mounted) setS(() {});
                                          },
                                          child: const Text('Liberar', style: TextStyle(fontSize: 12)),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: _C.card,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: _C.border),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _svc.mpLoaded ? Icons.check_circle : Icons.info_outline,
                                          size: 14,
                                          color: _svc.mpLoaded ? _C.ok : _C.textLo,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(_svc.mpStatus,
                                              style: const TextStyle(color: _C.textLo, fontSize: 11.5, height: 1.4)),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_svc.mpLoaded) ...[
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: _mpPrompt,
                                      minLines: 1,
                                      maxLines: 3,
                                      style: const TextStyle(color: _C.textHi, fontSize: 13),
                                      decoration: InputDecoration(
                                        filled: true,
                                        fillColor: _C.card,
                                        contentPadding: const EdgeInsets.all(10),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: _C.border),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: _C.border),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: _C.accent),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _C.accent,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(vertical: 10),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            icon: _svc.mpGenerating
                                                ? const SizedBox(width: 14, height: 14,
                                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                                : const Icon(Icons.play_arrow_rounded, size: 16),
                                            label: Text(_svc.mpGenerating ? 'Generando...' : 'Probar'),
                                            onPressed: (!_svc.mpLoaded || _svc.mpGenerating)
                                                ? null
                                                : () async {
                                                    await _svc.generateMpTest(_mpPrompt.text);
                                                    if (mounted) setS(() {});
                                                  },
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _svc.mpServerRunning ? _C.card : _C.accent,
                                              foregroundColor: _svc.mpServerRunning ? _C.textLo : Colors.white,
                                              padding: const EdgeInsets.symmetric(vertical: 10),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            icon: Icon(
                                                _svc.mpServerRunning ? Icons.stop : Icons.play_arrow_rounded, size: 16),
                                            label: Text(_svc.mpServerRunning ? 'Detener :8090' : 'Iniciar :8090'),
                                            onPressed: _svc.mpServerBusy
                                                ? null
                                                : () async {
                                                    if (_svc.mpServerRunning) {
                                                      await _svc.stopMpServer();
                                                    } else {
                                                      await _svc.startMpServer();
                                                    }
                                                    if (mounted) setS(() {});
                                                  },
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_svc.mpStats.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: _C.accent.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: _C.accent.withValues(alpha: 0.4)),
                                        ),
                                        child: Text(_svc.mpStats,
                                            style: const TextStyle(
                                                color: _C.accent,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                fontFamily: 'monospace')),
                                      ),
                                    ],
                                    if (_svc.mpOutput.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: _C.card,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: _C.border),
                                        ),
                                        child: SelectableText(_svc.mpOutput,
                                            style: const TextStyle(color: _C.textHi, fontSize: 12.5, height: 1.45)),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],

                          if (_selSource == 'custom') ...[
                            _cfgLabel('URL base'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: baseUrlCtrl,
                              style: const TextStyle(
                                  color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
                              decoration: _fieldDeco(hint: 'https://.../v1'),
                            ),
                            const SizedBox(height: 14),
                            _cfgLabel('Modelo'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: modelCtrl,
                              style: const TextStyle(
                                  color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
                              decoration: _fieldDeco(hint: 'nombre-del-modelo'),
                            ),
                            const SizedBox(height: 14),
                            _cfgLabel('API key'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: keyCtrl,
                              obscureText: obscureKey,
                              style: const TextStyle(
                                  color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
                              decoration: _fieldDeco(hint: '(opcional)').copyWith(
                                suffixIcon: IconButton(
                                  icon: Icon(
                                      obscureKey ? Icons.visibility_off : Icons.visibility,
                                      size: 18, color: _C.off),
                                  onPressed: () => setS(() => obscureKey = !obscureKey),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'La key se guarda solo en la app (no en el rootfs) y se inyecta al agente como variable de entorno efimera.',
                              style: TextStyle(color: _C.off, fontSize: 11, height: 1.4),
                            ),
                            const SizedBox(height: 18),
                          ],

                          const Divider(color: _C.border),
                          const SizedBox(height: 14),
                          _cfgLabel('Parametros de inferencia'),
                          const SizedBox(height: 10),
                          _cfgSlider('Temperature', temp, 0.0, 2.0, 40,
                              temp.toStringAsFixed(2), (v) => setS(() => temp = v)),
                          _cfgSlider('Top-p', topP, 0.0, 1.0, 20,
                              topP.toStringAsFixed(2), (v) => setS(() => topP = v)),
                          const SizedBox(height: 6),
                          _cfgStepper('Top-k', topK, 1, 100, 4,
                              (v) => setS(() => topK = v)),
                          const SizedBox(height: 18),
                          _cfgLabel('Puerto agent-server'),
                          const SizedBox(height: 6),
                          TextField(
                            controller: agentPortCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                                color: _C.textHi, fontSize: 14, fontFamily: 'monospace'),
                            decoration: _fieldDeco(),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _C.accent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: const Text('Guardar'),
                              onPressed: () async {
                                await _svc.setSource(
                                  id: _selSource,
                                  baseUrl: baseUrlCtrl.text.trim(),
                                  model: modelCtrl.text.trim(),
                                  apiKey: keyCtrl.text.trim(),
                                );
                                _svc.temp = temp;
                                _svc.topP = topP;
                                _svc.topK = topK;
                                _svc.agentPort =
                                    int.tryParse(agentPortCtrl.text.trim()) ??
                                        _svc.agentPort;
                                await _svc.saveSettings();
                                final wasAgent = _svc.agentLaunched;
                                if (wasAgent) _svc.stopAgent();
                                if (mounted) setState(() {});
                                if (mounted) Navigator.pop(ctx);
                                _snack('Ajustes guardados. Reinicia el agente para aplicar.');
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sourceChip(String id, String label, StateSetter setS,
      TextEditingController baseCtrl, TextEditingController modelCtrl) {
    final selected = id == _selSource;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      labelStyle: TextStyle(
        color: selected ? Colors.white : _C.textLo,
        fontSize: 12.5,
      ),
      backgroundColor: _C.card,
      selectedColor: _C.accent,
      side: BorderSide(color: selected ? _C.accent : _C.border),
      onSelected: (_) {
        setState(() => _selSource = id);
        setS(() {
          if (id == 'gpu_local') {
            baseCtrl.text = 'http://127.0.0.1:8090/v1';
            modelCtrl.text = 'gemma3-local';
          }
        });
      },
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.history, size: 19, color: _C.textLo),
                      const SizedBox(width: 8),
                      const Text('Conversaciones',
                          style: TextStyle(
                              color: _C.textHi,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close,
                            size: 20, color: _C.textLo),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _C.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _C.accent,
                            side: const BorderSide(color: _C.border),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          icon: const Icon(Icons.save_outlined, size: 17),
                          label: const Text('Guardar actual'),
                          onPressed: _ctrl.blocks.value.isEmpty
                              ? null
                              : () async {
                                  final name = await _promptName();
                                  if (name == null) return;
                                  await _ctrl.saveAs(name);
                                  setS(() {});
                                  _snack('Conversacion guardada.');
                                },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _C.textLo,
                            side: const BorderSide(color: _C.border),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          icon: const Icon(Icons.add_comment_outlined, size: 17),
                          label: const Text('Nueva'),
                          onPressed: () {
                            _ctrl.clear();
                            if (mounted) setState(() {});
                            Navigator.pop(ctx);
                            _snack('Nueva conversacion.');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 16, 6),
                    child: _cfgLabel('Guardadas'),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<SavedChat>>(
                    future: _ctrl.listSaved(),
                    builder: (_, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                            child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: _C.accent)));
                      }
                      final saved = snap.data ?? [];
                      if (saved.isEmpty) {
                        return const Center(
                          child: Text('No hay conversaciones guardadas.',
                              style: TextStyle(color: _C.off, fontSize: 13)),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: saved.length,
                        itemBuilder: (_, i) {
                          final sc = saved[i];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: _C.card,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _C.border),
                            ),
                            child: ListTile(
                              dense: true,
                              leading: const Icon(Icons.chat_bubble_outline,
                                  color: _C.textLo, size: 18),
                              title: Text(sc.name,
                                  style: const TextStyle(
                                      color: _C.textHi, fontSize: 13.5),
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(sc.dateLabel,
                                  style: const TextStyle(
                                      color: _C.off, fontSize: 11.5)),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 19, color: _C.off),
                                onPressed: () async {
                                  await _ctrl.deleteSaved(sc.path);
                                  setS(() {});
                                },
                              ),
                              onTap: () async {
                                await _ctrl.loadSaved(sc.path);
                                if (mounted) setState(() {});
                                if (!mounted) return;
                                Navigator.pop(ctx);
                                _scrollToBottom();
                                _snack('Conversacion cargada.');
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<String?> _promptName() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Guardar conversacion',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: _fieldDeco(hint: 'Nombre'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: _C.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Guardar', style: TextStyle(color: _C.accent)),
          ),
        ],
      ),
    );
  }

  Widget _cfgLabel(String t) => Text(
        t.toUpperCase(),
        style: const TextStyle(
            color: _C.textLo,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6),
      );

  Widget _cfgStepper(String label, int value, int min, int max, int step,
      ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(color: _C.textHi, fontSize: 14)),
        ),
        IconButton(
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
          icon: const Icon(Icons.remove_circle_outline, size: 22),
          color: _C.accent,
          disabledColor: _C.off,
        ),
        SizedBox(
          width: 44,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: _C.textHi,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
        ),
        IconButton(
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
          icon: const Icon(Icons.add_circle_outline, size: 22),
          color: _C.accent,
          disabledColor: _C.off,
        ),
      ],
    );
  }

  Widget _cfgSlider(String label, double value, double min, double max,
      int divisions, String valueLabel, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(color: _C.textHi, fontSize: 14)),
            const Spacer(),
            Text(valueLabel,
                style: const TextStyle(
                    color: _C.accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace')),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: _C.accent,
            inactiveTrackColor: _C.border,
            thumbColor: _C.accent,
            overlayColor: _C.accent.withValues(alpha: 0.15),
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  InputDecoration _fieldDeco({String? hint}) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: const TextStyle(color: _C.off, fontSize: 13),
      filled: true,
      fillColor: _C.card,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _C.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _C.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _C.accent),
      ),
    );
  }
}
