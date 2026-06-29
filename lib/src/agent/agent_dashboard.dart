// ignore_for_file: use_build_context_synchronously
// lib/src/agent/agent_dashboard.dart
//
// Panel del Agente Autónomo para XTR Terminal.
// - Tarjetas de servicio con start/stop + logs.
// - Fuente de inferencia: local / LAN / proveedor en la nube (OpenAI-compat).
// - Selección de modelo local (.gguf) + descarga HF.
// - Configuración: parámetros de inferencia + puertos.
// - Chat con pasos ReAct en streaming (SSE).

import 'mediapipe_test_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_services.dart';
import 'agent_chat.dart';

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
}

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35);

/// Preset de un proveedor de inferencia compatible con OpenAI.
class _Provider {
  final String id;
  final String label;
  final String baseUrl;
  final List<String> models;
  final String keyHint;
  final String note;
  final bool isLocal;
  final bool editableUrl;
  const _Provider({
    required this.id,
    required this.label,
    this.baseUrl = '',
    this.models = const [],
    this.keyHint = '',
    this.note = '',
    this.isLocal = false,
    this.editableUrl = false,
  });
}

const List<_Provider> _providers = [
  _Provider(id: 'local', label: 'Local', isLocal: true),
  _Provider(
    id: 'lan',
    label: 'LAN',
    baseUrl: 'http://192.168.1.50:8080/v1',
    editableUrl: true,
    note:
        'Otro equipo de tu red corriendo llama. Cambia la IP por la del equipo. '
        'Privado: no sale de tu red.',
  ),
  _Provider(
    id: 'groq',
    label: 'Groq · gratis',
    baseUrl: 'https://api.groq.com/openai/v1',
    models: [
      'llama-3.3-70b-versatile',
      'llama-3.1-8b-instant',
      'qwen/qwen3-32b',
      'openai/gpt-oss-120b',
    ],
    keyHint: 'gsk_...',
    note:
        'Gratis sin tarjeta, muy rápido y NO entrena con tus datos. '
        'La mejor opción gratuita para el agente.',
  ),
  _Provider(
    id: 'gemini',
    label: 'Gemini · gratis',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/',
    models: ['gemini-3.5-flash', 'gemini-2.5-flash', 'gemini-2.5-flash-lite'],
    keyHint: 'AIza...',
    note:
        'Gratis y muy generoso (1500 req/día). OJO: en la capa gratis Google '
        'entrena con tus prompts. No uses datos sensibles.',
  ),
  _Provider(
    id: 'cerebras',
    label: 'Cerebras · gratis',
    baseUrl: 'https://api.cerebras.ai/v1',
    models: ['llama-3.3-70b', 'llama3.1-8b'],
    keyHint: 'csk-...',
    note: '1M tokens/día gratis, muy rápido.',
  ),
  _Provider(
    id: 'openrouter',
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      'meta-llama/llama-3.3-70b-instruct:free',
      'deepseek/deepseek-r1:free',
    ],
    keyHint: 'sk-or-...',
    note: 'Muchos modelos; los que terminan en ":free" son gratis.',
  ),
  _Provider(
    id: 'xai',
    label: 'xAI Grok',
    baseUrl: 'https://api.x.ai/v1',
    models: ['grok-3-fast', 'grok-4.3', 'grok-code-fast-1'],
    keyHint: 'xai-...',
    note: 'De pago (sin capa gratuita). Necesita créditos en tu cuenta xAI.',
  ),
  _Provider(
    id: 'gpu_local',
    label: 'GPU Local 🔥',
    baseUrl: 'http://127.0.0.1:8090/v1',
    models: ['gemma3-local'],
    note: 'MediaPipe en GPU Adreno — 100% local y privado. '
        'Carga un modelo .task desde la pantalla GPU antes de arrancar.',
  ),
  _Provider(
    id: 'custom',
    label: 'Personalizado',
    editableUrl: true,
    note: 'Cualquier endpoint compatible con OpenAI. Acaba la URL en /v1.',
  ),
];

_Provider _providerById(String id) =>
    _providers.firstWhere((p) => p.id == id, orElse: () => _providers.first);


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

  Timer? _healthTimer;
  bool _llamaUp = false;
  bool _agentUp = false;

  @override
  void initState() {
    super.initState();
    _ctrl.ensureLoaded().then((_) {
      if (mounted) {
        setState(() {});
        _scrollToBottom();
      }
    });
    _svc.loadModelConfig().then((_) {
      if (mounted) {
        setState(() {});
        _pollHealth();
      }
    });
    // Dar tiempo a uvicorn para arrancar antes del primer check
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _pollHealth();
    });
    _healthTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _pollHealth());
    _svc.llamaStarting.addListener(_onSvc);
    _svc.agentStarting.addListener(_onSvc);
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _svc.llamaStarting.removeListener(_onSvc);
    _svc.agentStarting.removeListener(_onSvc);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSvc() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _pollHealth() async {
    final l = _svc.usingRemote ? false : await AgentApi.checkHealth(_svc.llamaPort);
    final a = await AgentApi.checkHealth(_svc.agentPort);
    if (mounted) {
      setState(() {
        _llamaUp = l;
        _agentUp = a;
      });
    }
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
          'El agent-server (:${_svc.agentPort}) no responde. Arráncalo primero.');
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

  // ---- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _C.bg,
      child: Column(
        children: [
          _header(),
          _serviceRow(),
          const Divider(height: 1, color: _C.border),
          Expanded(child: _chatList()),
          _inputBar(),
        ],
      ),
    );
  }

  String _headerSubtitle() {
    if (_svc.usingRemote) {
      final p = _providerById(_svc.sourceId);
      final m = _svc.remoteModel.isNotEmpty ? ' · ${_svc.remoteModel}' : '';
      return '${p.label}$m';
    }
    return _svc.usingLocalModel ? 'Gemma local' : _svc.llamaModelRef;
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 4, 8),
      child: Row(
        children: [
          const Text('Agente',
              style: TextStyle(
                  color: _C.textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _headerSubtitle(),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _C.textLo, fontSize: 12.5),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Configuración',
            onPressed: _showConfigSheet,
            icon: const Icon(Icons.tune, size: 20, color: _C.textLo),
          ),
          IconButton(
            tooltip: 'Fuente y modelo',
            onPressed: _showModelSheet,
            icon: const Icon(Icons.memory, size: 21, color: _C.textLo),
          ),
          IconButton(
            tooltip: 'Conversaciones',
            onPressed: _showHistorySheet,
            icon: const Icon(Icons.history, size: 21, color: _C.textLo),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: 'Abrir terminal',
              onPressed: widget.onClose,
              icon: const Icon(Icons.terminal, size: 22, color: _C.textLo),
            ),
        ],
      ),
    );
  }

  Widget _serviceRow() {
    final agentActive = _agentUp || _svc.agentLaunched;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: (_svc.sourceId != 'local')
                ? _remoteSourceCard()
                : _serviceCard(
                    name: 'llama-server',
                    port: _svc.llamaPort,
                    up: _llamaUp,
                    starting: _svc.llamaStarting.value,
                    active: _llamaUp || _svc.llamaLaunched,
                    onToggle: () => (_llamaUp || _svc.llamaLaunched)
                        ? _svc.stopLlama()
                        : _svc.startLlama(),
                    onLogs: () => _showLogs('llama-server', _svc.llamaLog),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _serviceCard(
              name: 'agent-server',
              port: _svc.agentPort,
              up: _agentUp,
              starting: _svc.agentStarting.value,
              active: agentActive,
              onToggle: () =>
                  agentActive ? _svc.stopAgent() : _svc.startAgent(),
              onLogs: () => _showLogs('agent-server', _svc.agentLog),
            ),
          ),
        ],
      ),
    );
  }

  Widget _remoteSourceCard() {
    final p = _providerById(_svc.sourceId);
    return InkWell(
      onTap: _showModelSheet,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _C.accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_outlined, size: 18, color: _C.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.label,
                      style: const TextStyle(
                          color: _C.textHi,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    _svc.remoteModel.isNotEmpty
                        ? _svc.remoteModel
                        : 'fuente remota',
                    style: const TextStyle(color: _C.textLo, fontSize: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: _C.off),
          ],
        ),
      ),
    );
  }

  Widget _serviceCard({
    required String name,
    required int port,
    required bool up,
    required bool starting,
    required bool active,
    required VoidCallback onToggle,
    required VoidCallback onLogs,
  }) {
    final dotColor = up ? _C.ok : (starting ? _C.accent : _C.off);
    final status = up
        ? 'Running · :$port'
        : (starting ? 'Arrancando…' : 'Detenido · :$port');
    return InkWell(
      onTap: onLogs,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _C.border),
        ),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration:
                  BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          color: _C.textHi,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(status,
                      style: TextStyle(
                          color: up ? _C.textLo : _C.off, fontSize: 11.5)),
                ],
              ),
            ),
            if (starting && !up)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent),
              )
            else
              IconButton(
                tooltip: active ? 'Detener' : 'Arrancar',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onToggle,
                icon: Icon(
                  active ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 24,
                  color: active ? _C.err : _C.ok,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Configuración --------------------------------------------------------

  void _showConfigSheet() {
    int threads = _svc.llamaThreads;
    int nCtx = _svc.llamaCtx;
    String kv = _svc.kvCacheType;
    double temp = _svc.temp;
    double topP = _svc.topP;
    int topK = _svc.topK;
    final llamaPortCtrl =
        TextEditingController(text: _svc.llamaPort.toString());
    final agentPortCtrl =
        TextEditingController(text: _svc.agentPort.toString());

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
                height: MediaQuery.of(ctx).size.height * 0.85,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 19, color: _C.textLo),
                          const SizedBox(width: 8),
                          const Text('Configuración',
                              style: TextStyle(
                                  color: _C.textHi,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setS(() {
                              _svc.resetSettings();
                              threads = _svc.llamaThreads;
                              nCtx = _svc.llamaCtx;
                              kv = _svc.kvCacheType;
                              temp = _svc.temp;
                              topP = _svc.topP;
                              topK = _svc.topK;
                              llamaPortCtrl.text = _svc.llamaPort.toString();
                              agentPortCtrl.text = _svc.agentPort.toString();
                            }),
                            child: const Text('Restablecer',
                                style: TextStyle(
                                    color: _C.textLo, fontSize: 12.5)),
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
                          if (_svc.usingRemote)
                            Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _C.cardAlt,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _C.border),
                              ),
                              child: const Text(
                                'Estos parámetros aplican al modelo LOCAL. '
                                'Ahora usas una fuente remota, así que no tienen efecto.',
                                style: TextStyle(
                                    color: _C.off, fontSize: 12, height: 1.4),
                              ),
                            ),
                          _cfgLabel('Inferencia (local)'),
                          const SizedBox(height: 10),
                          _cfgStepper('Hilos (-t)', threads, 1, 8, 1,
                              (v) => setS(() => threads = v)),
                          const SizedBox(height: 8),
                          _cfgChips(
                              'Contexto (-c)',
                              const ['4096', '8192', '16384'],
                              nCtx.toString(),
                              (v) => setS(() => nCtx = int.parse(v))),
                          const SizedBox(height: 8),
                          _cfgChips(
                              'KV cache',
                              const ['q4_0', 'q8_0', 'f16'],
                              kv,
                              (v) => setS(() => kv = v)),
                          const SizedBox(height: 4),
                          const Text(
                            'q4_0 = más rápido · q8_0 = equilibrio · f16 = sin cuantizar',
                            style: TextStyle(
                                color: _C.off, fontSize: 11.5, height: 1.4),
                          ),
                          const SizedBox(height: 22),
                          _cfgLabel('Muestreo'),
                          const SizedBox(height: 6),
                          _cfgSlider('Temperature', temp, 0.0, 2.0, 40,
                              temp.toStringAsFixed(2),
                              (v) => setS(() => temp = v)),
                          _cfgSlider('Top-p', topP, 0.0, 1.0, 20,
                              topP.toStringAsFixed(2),
                              (v) => setS(() => topP = v)),
                          const SizedBox(height: 6),
                          _cfgStepper('Top-k', topK, 1, 100, 4,
                              (v) => setS(() => topK = v)),
                          const SizedBox(height: 22),
                          _cfgLabel('Puertos'),
                          const SizedBox(height: 4),
                          const Text(
                            'agent_server.py los lee como LLAMA_PORT / AGENT_PORT.',
                            style: TextStyle(
                                color: _C.off, fontSize: 11.5, height: 1.4),
                          ),
                          const SizedBox(height: 10),
                          _cfgPortField('llama-server', llamaPortCtrl),
                          const SizedBox(height: 10),
                          _cfgPortField('agent-server', agentPortCtrl),
                          const SizedBox(height: 22),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _C.accent,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: const Text('Guardar'),
                              onPressed: () async {
                                _svc.llamaThreads = threads;
                                _svc.llamaCtx = nCtx;
                                _svc.kvCacheType = kv;
                                _svc.temp = temp;
                                _svc.topP = topP;
                                _svc.topK = topK;
                                _svc.llamaPort =
                                    int.tryParse(llamaPortCtrl.text.trim()) ??
                                        _svc.llamaPort;
                                _svc.agentPort =
                                    int.tryParse(agentPortCtrl.text.trim()) ??
                                        _svc.agentPort;
                                await _svc.saveSettings();
                                final wasLlama = _svc.llamaLaunched;
                                final wasAgent = _svc.agentLaunched;
                                if (wasLlama) _svc.stopLlama();
                                if (wasAgent) _svc.stopAgent();
                                if (mounted) setState(() {});
                                if (ctx.mounted) Navigator.pop(ctx);
                                _snack(
                                    'Configuración guardada. Reinicia los servicios para aplicar.');
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

  Widget _cfgChips(String label, List<String> opts, String sel,
      ValueChanged<String> onSel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _C.textHi, fontSize: 14)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: opts.map((o) {
            final selected = o == sel;
            return ChoiceChip(
              label: Text(o),
              selected: selected,
              showCheckmark: false,
              labelStyle: TextStyle(
                color: selected ? Colors.white : _C.textLo,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
              backgroundColor: _C.card,
              selectedColor: _C.accent,
              side: BorderSide(color: selected ? _C.accent : _C.border),
              onSelected: (_) => onSel(o),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _cfgPortField(String label, TextEditingController c) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label,
              style: const TextStyle(color: _C.textHi, fontSize: 14)),
        ),
        Expanded(
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
                color: _C.textHi, fontSize: 14, fontFamily: 'monospace'),
            decoration: _fieldDeco(),
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

  // ---- Fuente + modelo ------------------------------------------------------

  // ignore: use_build_context_synchronously
  void openModelSheet() => _showModelSheet();
  void _showModelSheet() {
    String selSource = _svc.sourceId;
    final baseUrlCtrl = TextEditingController(text: _svc.remoteBaseUrl);
    final modelCtrl = TextEditingController(text: _svc.remoteModel);
    final keyCtrl = TextEditingController(text: _svc.remoteApiKey);
    final hfController = TextEditingController(text: _svc.llamaModelRef);
    bool obscureKey = true;

    void applyPreset(_Provider p) {
      baseUrlCtrl.text = p.baseUrl;
      modelCtrl.text = p.models.isNotEmpty ? p.models.first : '';
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          final prov = _providerById(selSource);
          return Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.85,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.memory, size: 19, color: _C.textLo),
                        const SizedBox(width: 8),
                        const Text('Fuente y modelo',
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
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      children: [
                        _cfgLabel('Fuente de inferencia'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _providers.map((p) {
                            final selected = p.id == selSource;
                            return ChoiceChip(
                              label: Text(p.label),
                              selected: selected,
                              showCheckmark: false,
                              labelStyle: TextStyle(
                                color: selected ? Colors.white : _C.textLo,
                                fontSize: 12.5,
                              ),
                              backgroundColor: _C.card,
                              selectedColor: _C.accent,
                              side: BorderSide(
                                  color: selected ? _C.accent : _C.border),
                              onSelected: (_) => setS(() {
                                selSource = p.id;
                                if (!p.isLocal) applyPreset(p);
                              }),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 18),
                        if (prov.isLocal)
                          ..._localSection(ctx, hfController, setS)
                        else
                          ..._remoteSection(
                              ctx, prov, baseUrlCtrl, modelCtrl, keyCtrl,
                              obscureKey, () => setS(() => obscureKey = !obscureKey),
                              selSource),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  List<Widget> _remoteSection(
    BuildContext ctx,
    _Provider prov,
    TextEditingController baseUrlCtrl,
    TextEditingController modelCtrl,
    TextEditingController keyCtrl,
    bool obscureKey,
    VoidCallback toggleObscure,
    String selSource,
  ) {
    return [
      if (selSource == 'gpu_local') ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.bolt, color: Colors.orangeAccent),
          label: const Text('Gestionar modelo .task y servidor GPU',
              style: TextStyle(color: Colors.orangeAccent)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Colors.orangeAccent),
            minimumSize: const Size(double.infinity, 48),
          ),
          onPressed: () {
            Navigator.pop(ctx);
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MediaPipeTestScreen()),
            );
          },
        ),
        const SizedBox(height: 16),
      ],
      if (prov.note.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _C.cardAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.border),
          ),
          child: Text(prov.note,
              style:
                  const TextStyle(color: _C.textLo, fontSize: 12.5, height: 1.45)),
        ),
      _cfgLabel('URL base'),
      const SizedBox(height: 8),
      TextField(
        controller: baseUrlCtrl,
        enabled: prov.editableUrl,
        style: const TextStyle(
            color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
        decoration: _fieldDeco(hint: 'https://.../v1'),
      ),
      const SizedBox(height: 16),
      _cfgLabel('Modelo'),
      const SizedBox(height: 8),
      TextField(
        controller: modelCtrl,
        style: const TextStyle(
            color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
        decoration: _fieldDeco(hint: 'nombre-del-modelo'),
      ),
      if (prov.models.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: prov.models
              .map((m) => ActionChip(
                    label: Text(m, style: const TextStyle(fontSize: 11)),
                    backgroundColor: _C.cardAlt,
                    labelStyle: const TextStyle(color: _C.textLo),
                    side: const BorderSide(color: _C.border),
                    onPressed: () => modelCtrl.text = m,
                  ))
              .toList(),
        ),
      ],
      const SizedBox(height: 16),
      _cfgLabel('API key'),
      const SizedBox(height: 8),
      TextField(
        controller: keyCtrl,
        obscureText: obscureKey,
        style: const TextStyle(
            color: _C.textHi, fontSize: 13, fontFamily: 'monospace'),
        decoration: _fieldDeco(hint: prov.keyHint.isEmpty ? '(opcional)' : prov.keyHint)
            .copyWith(
          suffixIcon: IconButton(
            icon: Icon(obscureKey ? Icons.visibility_off : Icons.visibility,
                size: 18, color: _C.off),
            onPressed: toggleObscure,
          ),
        ),
      ),
      const SizedBox(height: 6),
      const Text(
        'La key se guarda solo en la app (no en el rootfs) y se inyecta al '
        'agente como variable de entorno efímera.',
        style: TextStyle(color: _C.off, fontSize: 11, height: 1.4),
      ),
      const SizedBox(height: 18),
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
          icon: const Icon(Icons.cloud_done_outlined, size: 18),
          label: const Text('Usar esta fuente'),
          onPressed: () async {
            final base = baseUrlCtrl.text.trim();
            if (base.isEmpty) {
              _snack('Indica la URL base (acaba en /v1).');
              return;
            }
            await _svc.setRemoteSource(
              id: selSource,
              baseUrl: base,
              model: modelCtrl.text.trim(),
              apiKey: keyCtrl.text.trim(),
            );
            final wasLlama = _svc.llamaLaunched;
            final wasAgent = _svc.agentLaunched;
            if (wasLlama) _svc.stopLlama();
            if (wasAgent) _svc.stopAgent();
            if (mounted) setState(() {});
            if (ctx.mounted) Navigator.pop(ctx);
            _snack('Fuente remota activa. Arranca el agent-server.');
          },
        ),
      ),
    ];
  }

  List<Widget> _localSection(
    BuildContext ctx,
    TextEditingController hfController,
    StateSetter setS,
  ) {
    return [
      _cfgLabel('Modelos locales (.gguf)'),
      const SizedBox(height: 8),
      FutureBuilder<List<ModelFile>>(
        future: _svc.scanLocalModels(),
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _C.accent))),
            );
          }
          final models = snap.data ?? [];
          if (models.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'No hay .gguf válidos en /root/models.\nDescarga uno por HF o cópialo por terminal.',
                  style: TextStyle(color: _C.off, fontSize: 13, height: 1.5)),
            );
          }
          return Column(
            children: models.map((m) => _modelRow(ctx, m, setS)).toList(),
          );
        },
      ),
      const SizedBox(height: 24),
      _cfgLabel('Descargar de Hugging Face'),
      const SizedBox(height: 8),
      const Text(
        'repo:quant — se descarga al arrancar (requiere internet la primera vez).',
        style: TextStyle(color: _C.off, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: hfController,
        style: const TextStyle(color: _C.textHi, fontSize: 13.5),
        decoration: _fieldDeco(hint: 'usuario/repo-GGUF:Q4_K_M'),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _suggestionChip('E2B Q4_K_M (rápido)',
              'unsloth/gemma-4-E2B-it-GGUF:Q4_K_M', hfController),
          _suggestionChip('E4B Q4_K_M (más calidad)',
              'unsloth/gemma-4-E4B-it-GGUF:Q4_K_M', hfController),
        ],
      ),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _C.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.cloud_download_outlined, size: 18),
          label: const Text('Usar este modelo HF'),
          onPressed: () async {
            final ref = hfController.text.trim();
            if (ref.isEmpty) return;
            await _svc.setHfModel(ref);
            final wasRunning = _svc.llamaLaunched;
            if (wasRunning) _svc.stopLlama();
            if (mounted) setState(() {});
            if (ctx.mounted) Navigator.pop(ctx);
            _snack('Modelo HF: $ref. Pulsa ▶ para descargar y arrancar.');
          },
        ),
      ),
    ];
  }

  Widget _modelRow(BuildContext sheetCtx, ModelFile m, StateSetter setS) {
    final selected = !_svc.usingRemote &&
        _svc.usingLocalModel &&
        _svc.llamaLocalModelPath == m.prootPath;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? _C.accent : _C.border),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          selected ? Icons.check_circle : Icons.insert_drive_file_outlined,
          color: selected ? _C.accent : _C.textLo,
          size: 20,
        ),
        title: Text(m.name,
            style: const TextStyle(color: _C.textHi, fontSize: 13),
            overflow: TextOverflow.ellipsis),
        subtitle: Text(m.sizeLabel,
            style: const TextStyle(color: _C.off, fontSize: 11.5)),
        onTap: () async {
          await _svc.setLocalModel(m.prootPath);
          final wasRunning = _svc.llamaLaunched;
          if (wasRunning) _svc.stopLlama();
          if (mounted) setState(() {});
          if (sheetCtx.mounted) Navigator.pop(sheetCtx);
          _snack('Modelo local: ${m.name}. Pulsa ▶ para arrancar.');
        },
      ),
    );
  }

  Widget _suggestionChip(
      String label, String ref, TextEditingController controller) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      backgroundColor: _C.cardAlt,
      labelStyle: const TextStyle(color: _C.textLo),
      side: const BorderSide(color: _C.border),
      onPressed: () => controller.text = ref,
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
          height: MediaQuery.of(ctx).size.height * 0.6,
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
                        child: Text('Sin logs todavía.',
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

  // ---- Historial de conversaciones -----------------------------------------

  Future<String?> _promptName() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Guardar conversación',
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
                                  _snack('Conversación guardada.');
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
                            _snack('Conversación nueva.');
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
                                _snack('Conversación cargada.');
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

  Widget _chatList() {
    return AnimatedBuilder(
      animation: Listenable.merge([_ctrl.blocks, _ctrl.running]),
      builder: (context, _) {
        final blocks = _ctrl.blocks.value;
        final running = _ctrl.running.value;
        if (blocks.isEmpty) {
          final hint = _agentUp
              ? 'Escribe una tarea para el agente.\nP. ej. "Crea un script en /root/scripts/hola.sh que imprima la fecha y ejecútalo".'
              : (_svc.usingRemote
                  ? 'Fuente remota activa.\nArranca solo el agent-server con el botón ▶.'
                  : 'Arranca llama-server y agent-server\ncon los botones de arriba.');
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: _C.off, fontSize: 13.5, height: 1.5),
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
            child:
                CircularProgressIndicator(strokeWidth: 2, color: _C.accent),
          ),
          SizedBox(width: 10),
          Text('razonando…', style: TextStyle(color: _C.textLo, fontSize: 13)),
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
              style:
                  const TextStyle(color: _C.textHi, fontSize: 14, height: 1.4)),
        );

      case 'thought':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            b.text,
            style: const TextStyle(
                color: _C.textLo,
                fontSize: 13,
                height: 1.45,
                fontStyle: FontStyle.italic),
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
          child: Text(b.text,
              style: const TextStyle(
                  color: _C.textHi, fontSize: 14.5, height: 1.5)),
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
                hintText: running ? 'Ejecutando…' : 'Tarea para el agente…',
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
}
