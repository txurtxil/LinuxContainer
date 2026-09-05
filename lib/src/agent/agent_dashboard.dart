// lib/src/agent/agent_dashboard.dart — v9.0
// MEJORAS: Animaciones en botones, indicadores de pensamiento elaborados,
//          seccion de Prompts Rapidos, escaneo de red con topologia visual,
//          configuracion simplificada, efectos visuales de carga.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:http/http.dart' as http;

import 'agent_services.dart';
import 'agent_chat.dart';
import 'prompt_templates.dart';
import 'ssh_connections.dart';

// ═══════════════════════════════════════════════════════════════════
//  PALETA DE COLORES
// ═══════════════════════════════════════════════════════════════════
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
  static const purple = Color(0xFFBF5AF2);
  static const orange = Color(0xFFFF9500);
  static const teal = Color(0xFF5AC8FA);
}

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35);

// ═══════════════════════════════════════════════════════════════════
//  ANIMACIONES REUTILIZABLES
// ═══════════════════════════════════════════════════════════════════

/// Indicador de ondas animadas — muestra que el modelo esta "pensando"
class _WaveThinkingIndicator extends StatefulWidget {
  final Color color;
  final double size;
  const _WaveThinkingIndicator({this.color = _C.accent, this.size = 24});

  @override
  State<_WaveThinkingIndicator> createState() => _WaveThinkingIndicatorState();
}

class _WaveThinkingIndicatorState extends State<_WaveThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (i) {
            final delay = i * 0.15;
            final t = (_ctrl.value + delay) % 1.0;
            final scale = 0.4 + 0.6 * sin(t * pi * 2);
            final opacity = 0.3 + 0.7 * sin(t * pi * 2);
            return Container(
              width: widget.size * 0.22,
              height: widget.size * scale,
              margin: EdgeInsets.symmetric(horizontal: widget.size * 0.06),
              decoration: BoxDecoration(
                color: widget.color.withOpacity(opacity.clamp(0.3, 1.0)),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Indicador de pulso — para botones en estado de carga
class _PulseRing extends StatefulWidget {
  final Widget child;
  final bool active;
  final Color color;
  const _PulseRing({required this.child, this.active = false, this.color = _C.accent});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.4).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _opacity = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _PulseRing old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (widget.active)
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) => Transform.scale(
              scale: _scale.value,
              child: Opacity(
                opacity: _opacity.value,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

/// Efecto shimmer para botones de carga
class _ShimmerButton extends StatefulWidget {
  final Widget child;
  final bool active;
  final Color baseColor;
  final Color shimmerColor;
  const _ShimmerButton({
    required this.child,
    this.active = false,
    this.baseColor = _C.accent,
    this.shimmerColor = _C.teal,
  });

  @override
  State<_ShimmerButton> createState() => _ShimmerButtonState();
}

class _ShimmerButtonState extends State<_ShimmerButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _ShimmerButton old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [
                widget.baseColor,
                widget.shimmerColor,
                widget.baseColor,
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment(-1.0 + _ctrl.value * 3.0, 0),
              end: Alignment(0.0 + _ctrl.value * 3.0, 0),
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcIn,
          child: widget.child,
        );
      },
    );
  }
}

/// Boton con estado de carga animado
class _AnimatedActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final bool disabled;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? textColor;
  final double? width;

  const _AnimatedActionButton({
    required this.label,
    required this.icon,
    this.loading = false,
    this.disabled = false,
    this.onPressed,
    this.color,
    this.textColor,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? _C.accent;
    final fg = textColor ?? Colors.white;
    final isBusy = loading || disabled;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: width,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: isBusy ? bg.withOpacity(0.6) : bg,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: isBusy ? 0 : 2,
        ),
        icon: loading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              )
            : Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        onPressed: isBusy ? null : onPressed,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  MODELOS DE DATOS PARA PROMPTS
// ═══════════════════════════════════════════════════════════════════

class _QuickPrompt {
  final String title;
  final String description;
  final String prompt;
  final IconData icon;
  final Color color;
  final String category;

  const _QuickPrompt({
    required this.title,
    required this.description,
    required this.prompt,
    required this.icon,
    required this.color,
    required this.category,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  DASHBOARD PRINCIPAL
// ═══════════════════════════════════════════════════════════════════

class AgentDashboard extends StatefulWidget {
  final VoidCallback? onClose;
  const AgentDashboard({super.key, this.onClose});

  @override
  State<AgentDashboard> createState() => _AgentDashboardState();
}

class _AgentDashboardState extends State<AgentDashboard>
    with TickerProviderStateMixin {
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
  bool _showAutonomous = false;

  bool _showPromptsPanel = false;
  String _promptCategory = 'Todos';

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
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: _C.card,
      ),
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

  void _sendPrompt(String prompt) {
    _input.text = prompt;
    _send();
    setState(() => _showPromptsPanel = false);
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

  List<_QuickPrompt> get _allPrompts => [
        // TITULOS Y DESCRIPCIONES EN ESPANOL (para el usuario)
        // PROMPTS EN INGLES (para que Gemma 2B/4B obedezca)
        _QuickPrompt(
          title: 'Escanear red local',
          description: 'Descubre equipos, puertos y genera mapa topologico',
          prompt:
              'Scan the local network. First find the subnet with "ip route". '
              'Then use nmap to discover active hosts and open ports (22,80,443,3389,8080,21,445,139,3306,5432). '
              'Identify OS and services. Generate a network topology image with Graphviz at /root/scan_red.png '
              'showing each device with IP, hostname, open ports, and device type colors. '
              'Show a text summary table of found hosts.',
          icon: Icons.network_check,
          color: _C.teal,
          category: 'Red',
        ),
        _QuickPrompt(
          title: 'Auditoria de seguridad',
          description: 'Analiza vulnerabilidades basicas del sistema',
          prompt:
              'Run a basic security audit on this Debian system. Check: users with shell, listening services, '
              'suspicious SUID permissions, firewall rules, pending updates, SSH config. '
              'Generate a markdown report at /root/audit_security.md with severity (high/medium/low) and hardening recommendations.',
          icon: Icons.security,
          color: _C.err,
          category: 'Red',
        ),
        _QuickPrompt(
          title: 'Monitor de trafico',
          description: 'Captura y analiza trafico de red',
          prompt:
              'Monitor network traffic using tcpdump or tshark for 60 seconds. '
              'Analyze most used protocols, active connections, and anomalies. '
              'Generate a bar chart with matplotlib at /root/traffic.png showing traffic by protocol. Show text summary.',
          icon: Icons.speed,
          color: _C.warn,
          category: 'Red',
        ),
        _QuickPrompt(
          title: 'Info del sistema',
          description: 'Recursos, procesos y estado del hardware',
          prompt:
              'Get complete system info: CPU, RAM, disk, processes, temperature, load, uptime. '
              'Generate a visual dashboard with matplotlib at /root/sysinfo.png. Present data clearly.',
          icon: Icons.computer,
          color: _C.ok,
          category: 'Sistema',
        ),
        _QuickPrompt(
          title: 'Automatizar tarea',
          description: 'Script cron para backup automatico',
          prompt:
              'Create /root/backup_auto.sh that: 1) compressed backup of /root/documents to /root/backups with date, '
              '2) cleanup backups older than 7 days, 3) log to /var/log/backup.log. '
              'Set up a cron job to run daily at 3:00 AM. Show the script and verify cron is active.',
          icon: Icons.schedule,
          color: _C.purple,
          category: 'Sistema',
        ),
        _QuickPrompt(
          title: 'Crear API REST',
          description: 'FastAPI con endpoints basicos',
          prompt:
              'Create a REST API with FastAPI in /root/my_api/: GET /items, POST /items, GET /items/{id}, SQLite persistence. '
              'Include a curl test script. Run in background and verify it responds.',
          icon: Icons.code,
          color: _C.accent,
          category: 'Dev',
        ),
        _QuickPrompt(
          title: 'Generar QR',
          description: 'Codigos QR para URLs, WiFi, etc.',
          prompt:
              'Generate QR codes using qrencode: 1) https://github.com/txurtxil/LinuxContainer to /root/qr_repo.png, '
              '2) WiFi SSID:XTR-Guest to /root/qr_wifi.png, 3) phone +34600000000 to /root/qr_phone.png. '
              'Show all generated files.',
          icon: Icons.qr_code,
          color: _C.teal,
          category: 'Dev',
        ),
        _QuickPrompt(
          title: 'Diagrama de flujo',
          description: 'Diagrama del arranque de XTR',
          prompt:
              'Generate a flowchart with Graphviz at /root/flowchart.png showing XTR startup: '
              'App Flutter -> proot -> setup AI -> load MediaPipe -> agent-server -> chat. '
              'Use different shapes (rectangles, diamonds, ovals) and colors.',
          icon: Icons.account_tree,
          color: _C.orange,
          category: 'Visual',
        ),
        _QuickPrompt(
          title: 'Grafica de datos',
          description: 'Comparativa de modelos IA locales',
          prompt:
              'Generate a bar chart at /root/comparison.png with matplotlib comparing local AI models: '
              'Gemma3-1B (15 tok/s, 512MB), Gemma3-4B (8 tok/s, 1.2GB), Phi-4 (6 tok/s, 1.5GB), Qwen2.5 (10 tok/s, 900MB). '
              'Include title, legend, axis labels, and values on bars.',
          icon: Icons.bar_chart,
          color: _C.ok,
          category: 'Visual',
        ),
        _QuickPrompt(
          title: 'Convertir formato',
          description: 'JSON <-> YAML <-> CSV <-> TOML',
          prompt:
              'Create /root/converter.py that converts between JSON/YAML/CSV/TOML. '
              'Accept input file and output format as arguments. Create /root/test_data.json with sample data and demonstrate all conversions.',
          icon: Icons.transform,
          color: _C.purple,
          category: 'Util',
        ),
        _QuickPrompt(
          title: 'Encriptar archivo',
          description: 'Cifrado GPG con claves',
          prompt:
              'Generate a GPG key pair, create /root/secret.txt, encrypt it to /root/secret.txt.gpg, '
              'then decrypt to verify. Show commands used and explain the process. Include how to export the public key.',
          icon: Icons.lock,
          color: _C.err,
          category: 'Util',
        ),
      ];

  List<String> get _categories {
    final cats = _allPrompts.map((p) => p.category).toSet().toList()..sort();
    return ['Todos', ...cats];
  }

  List<_QuickPrompt> get _filteredPrompts {
    if (_promptCategory == 'Todos') return _allPrompts;
    return _allPrompts.where((p) => p.category == _promptCategory).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _C.bg,
      child: Column(
        children: [
          _header(),
          if (_showAutonomous)
            Expanded(child: AgentAutonomousPanel())
          else ...[
            Expanded(child: _chatList()),
            if (_showPromptsPanel) _promptsPanel(),
            _inputBar(),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  HEADER
  // ═══════════════════════════════════════════════════════════════════

  Widget _header() {
    final agentActive = _agentUp || _svc.agentLaunched;
    final failed = _svc.agentFailed.value;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      decoration: BoxDecoration(
        color: _C.bg,
        border: Border(
          bottom: BorderSide(
            color: agentActive ? _C.accent.withOpacity(0.3) : _C.border,
            width: agentActive ? 1.5 : 1,
          ),
        ),
      ),
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
          _StatusDot(
            failed: failed,
            starting: _svc.agentStarting.value,
            active: agentActive,
          ),
          const SizedBox(width: 8),
          if (_svc.agentStarting.value && !_agentUp)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent),
            )
          else
            _PulseRing(
              active: _svc.agentStarting.value,
              child: IconButton(
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
            ),
          const SizedBox(width: 4),
          // Cabecera compacta (Fold pantalla pequena): solo lo esencial
          // visible; el resto va al menu de overflow (⋯).
          IconButton(
            tooltip: 'Prompts rapidos',
            onPressed: () =>
                setState(() => _showPromptsPanel = !_showPromptsPanel),
            icon: Icon(
              Icons.lightbulb_outline,
              size: 20,
              color: _showPromptsPanel ? _C.accent : _C.textLo,
            ),
          ),
          IconButton(
            tooltip: _showAutonomous ? 'Volver al chat' : 'Modo autonomo',
            onPressed: () =>
                setState(() => _showAutonomous = !_showAutonomous),
            icon: Icon(
              _showAutonomous
                  ? Icons.chat_bubble_outline
                  : Icons.psychology_outlined,
              size: 20,
              color: _showAutonomous ? _C.purple : _C.textLo,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Mas opciones',
            icon: Icon(Icons.more_vert,
                size: 20, color: failed ? _C.err : _C.textLo),
            color: _C.card,
            onSelected: (v) {
              switch (v) {
                case 'logs':
                  _showLogs('agent-server', _svc.agentLog);
                  break;
                case 'gallery':
                  _showImageGallery();
                  break;
                case 'settings':
                  _showSettingsSheet();
                  break;
                case 'history':
                  _showHistorySheet();
                  break;
                case 'terminal':
                  widget.onClose?.call();
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'gallery',
                child: _MenuRow(icon: Icons.photo_library_outlined, label: 'Galeria de imagenes'),
              ),
              const PopupMenuItem(
                value: 'logs',
                child: _MenuRow(icon: Icons.article_outlined, label: 'Logs del agente'),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: _MenuRow(icon: Icons.tune, label: 'Ajustes'),
              ),
              const PopupMenuItem(
                value: 'history',
                child: _MenuRow(icon: Icons.history, label: 'Historial'),
              ),
              if (widget.onClose != null)
                const PopupMenuItem(
                  value: 'terminal',
                  child: _MenuRow(icon: Icons.terminal, label: 'Terminal'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LISTA DE CHAT
  // ═══════════════════════════════════════════════════════════════════

  Widget _chatList() {
    return AnimatedBuilder(
      animation: Listenable.merge([_ctrl.blocks, _ctrl.running]),
      builder: (context, _) {
        final blocks = _ctrl.blocks.value;
        final running = _ctrl.running.value;
        if (blocks.isEmpty) {
          final hint = _agentUp
              ? 'Escribe una tarea o usa los Prompts Rapidos (bombilla).\n\n'
                  'Ejemplo: "Escanea la red local y genera un mapa topologico".'
              : (_svc.agentStarting.value
                  ? 'Arrancando agent-server... espera unos segundos.'
                  : 'Pulsa el boton verde de play para arrancar el agent-server.');
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _agentUp ? Icons.psychology : Icons.smart_toy_outlined,
                    size: 48,
                    color: _C.off.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: _C.off, fontSize: 13.5, height: 1.5),
                  ),
                  if (!_agentUp && !_svc.agentStarting.value) ...[
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _C.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Arrancar Agente'),
                      onPressed: () {
                        _svc.startAgent();
                        _startBootPoll();
                      },
                    ),
                  ],
                ],
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

  // ═══════════════════════════════════════════════════════════════════
  //  INDICADOR DE PENSAMIENTO MEJORADO
  // ═══════════════════════════════════════════════════════════════════

  Widget _thinkingRow() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _C.cardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.accent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _C.accent.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El modelo esta procesando...',
                  style: TextStyle(
                    color: _C.textHi,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _WaveThinkingIndicator(color: _C.accent, size: 20),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop_rounded, size: 14, color: _C.err),
            label:
                const Text('Detener', style: TextStyle(color: _C.err, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  BLOQUES DE CHAT
  // ═══════════════════════════════════════════════════════════════════

  // ── Visor de imagenes generadas por el agente ──────────────────────────

  List<String> _extractImagePaths(String text) {
    final re = RegExp(r'(/(?:root|tmp)/[^\s"()]*\.(?:png|jpe?g|gif|webp))');
    return re.allMatches(text).map((m) => m.group(1)!).toSet().toList();
  }

  String _fileUrl(String path) =>
      'http://127.0.0.1:8765/file?path=${Uri.encodeComponent(path)}';

  List<Widget> _imagesFor(String text) {
    return _extractImagePaths(text)
        .map((p) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _imageThumb(p),
            ))
        .toList();
  }

  Widget _imageThumb(String path) {
    return GestureDetector(
      onTap: () => _showImageFullscreen(path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(border: Border.all(color: _C.border)),
          child: Image.network(
            _fileUrl(path),
            fit: BoxFit.contain,
            loadingBuilder: (c, w, prog) => prog == null
                ? w
                : const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _C.accent)),
            errorBuilder: (c, e, st) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No se pudo cargar $path',
                  style: const TextStyle(color: _C.err, fontSize: 11)),
            ),
          ),
        ),
      ),
    );
  }

  void _showImageFullscreen(String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (_) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(8),
          child: InteractiveViewer(
            maxScale: 6,
            child: Image.network(_fileUrl(path), fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Future<void> _showImageGallery() async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:8765/files/images'))
          .timeout(const Duration(seconds: 8));
      final images =
          (json.decode(resp.body)['images'] as List?) ?? const [];
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Imagenes del agente',
              style: TextStyle(color: _C.textHi, fontSize: 15)),
          content: SizedBox(
            width: 400,
            height: 400,
            child: images.isEmpty
                ? const Center(
                    child: Text('Aun no hay imagenes generadas',
                        style: TextStyle(color: _C.textLo)))
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8),
                    itemCount: images.length,
                    itemBuilder: (c, i) {
                      final p = images[i]['path'].toString();
                      return GestureDetector(
                        onTap: () {
                          Navigator.of(context).pop();
                          _showImageFullscreen(p);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(_fileUrl(p),
                              fit: BoxFit.cover,
                              errorBuilder: (c2, e, st) => Container(
                                  color: _C.cardAlt,
                                  child: const Icon(Icons.broken_image,
                                      color: _C.off))),
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    } catch (e) {
      _snack('Agente no disponible');
    }
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
              style: const TextStyle(
                  color: _C.textHi, fontSize: 14, height: 1.4)),
        );

      case 'thought':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(right: 8, top: 2),
                decoration: BoxDecoration(
                  color: _C.accent.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.psychology,
                    size: 12, color: _C.accent),
              ),
              Expanded(
                child: Text(
                  b.text,
                  style: const TextStyle(
                      color: _C.textLo,
                      fontSize: 13,
                      height: 1.45,
                      fontStyle: FontStyle.italic),
                ),
              ),
            ],
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
                  const Icon(Icons.terminal_rounded,
                      size: 15, color: _C.accent),
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
                        style:
                            const TextStyle(color: _C.off, fontSize: 11)),
                  ],
                ],
              ),
              if (b.toolArgs != null && b.toolArgs!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(b.toolArgs!,
                    style: _mono.copyWith(color: _C.textHi)),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.text, style: _mono.copyWith(color: _C.textLo)),
                ..._imagesFor(b.text),
              ],
            ),
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
                      color: _C.textHi,
                      fontSize: 14.5,
                      height: 1.5)),
              ..._imagesFor(b.text),
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
                    Text('Copiar',
                        style: TextStyle(
                            color: _C.off, fontSize: 11.5)),
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
              const Icon(Icons.error_outline,
                  size: 16, color: _C.err),
              const SizedBox(width: 8),
              Expanded(
                child: Text(b.text,
                    style: const TextStyle(
                        color: Color(0xFFE5B5B5),
                        fontSize: 13,
                        height: 1.4)),
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  PANEL DE PROMPTS RAPIDOS
  // ═══════════════════════════════════════════════════════════════════

  Widget _promptsPanel() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      height: 280,
      decoration: BoxDecoration(
        color: _C.cardAlt,
        border: Border(
          top: BorderSide(
              color: _C.accent.withOpacity(0.3), width: 1.5),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                const Icon(Icons.lightbulb,
                    size: 16, color: _C.accent),
                const SizedBox(width: 8),
                const Text('Prompts Rapidos',
                    style: TextStyle(
                        color: _C.textHi,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    shrinkWrap: true,
                    itemCount: _categories.length,
                    itemBuilder: (context, i) {
                      final cat = _categories[i];
                      final selected = cat == _promptCategory;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(cat,
                              style: const TextStyle(fontSize: 11)),
                          selected: selected,
                          showCheckmark: false,
                          labelStyle: TextStyle(
                            color: selected
                                ? Colors.white
                                : _C.textLo,
                            fontSize: 11,
                          ),
                          backgroundColor: _C.card,
                          selectedColor: _C.accent,
                          side: BorderSide(
                            color: selected
                                ? _C.accent
                                : _C.border,
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8),
                          onSelected: (_) => setState(
                              () => _promptCategory = cat),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 18, color: _C.textLo),
                  onPressed: () =>
                      setState(() => _showPromptsPanel = false),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _C.border),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 2.8,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: _filteredPrompts.length,
              itemBuilder: (context, i) {
                final p = _filteredPrompts[i];
                return _PromptCard(
                  prompt: p,
                  onTap: () => _sendPrompt(p.prompt),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  BARRA DE INPUT
  // ═══════════════════════════════════════════════════════════════════

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
                        final data =
                            await Clipboard.getData('text/plain');
                        final text = data?.text;
                        if (text != null && text.isNotEmpty) {
                          _input.text = _input.text.isEmpty
                              ? text
                              : '${_input.text} $text';
                        }
                      },
                icon: const Icon(Icons.content_paste,
                    size: 20, color: _C.off),
                tooltip: 'Pegar',
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !running,
                  minLines: 1,
                  maxLines: 6,
                  style: const TextStyle(
                      color: _C.textHi, fontSize: 14.5),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: running
                        ? 'Procesando tarea...'
                        : 'Tarea para el agente...',
                    hintStyle:
                        const TextStyle(color: _C.off, fontSize: 14),
                    filled: true,
                    fillColor: _C.card,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _C.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _C.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _C.accent),
                    ),
                    suffixIcon: running
                        ? null
                        : IconButton(
                            icon: const Icon(
                                Icons.lightbulb_outline,
                                size: 18,
                                color: _C.off),
                            onPressed: () => setState(() =>
                                _showPromptsPanel =
                                    !_showPromptsPanel),
                            tooltip: 'Prompts rapidos',
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              running
                  ? _PulseRing(
                      active: true,
                      color: _C.err,
                      child: IconButton(
                        onPressed: _stop,
                        style: IconButton.styleFrom(
                          backgroundColor: _C.card,
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(12)),
                          padding: const EdgeInsets.all(12),
                        ),
                        icon: const Icon(Icons.stop_rounded,
                            color: _C.err),
                      ),
                    )
                  : _ShimmerButton(
                      active: _svc.agentStarting.value,
                      child: IconButton(
                        onPressed: _send,
                        style: IconButton.styleFrom(
                          backgroundColor: _C.accent,
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(12)),
                          padding: const EdgeInsets.all(12),
                        ),
                        icon: const Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.white),
                      ),
                    ),
            ],
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LOGS
  // ═══════════════════════════════════════════════════════════════════

  void _showLogs(String title, ValueNotifier<List<String>> log) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final logScroll = ScrollController();
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.65,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(18, 14, 8, 8),
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
                      icon: const Icon(Icons.close,
                          size: 20, color: _C.textLo),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _C.border),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: log,
                  builder: (_, lines, __) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) {
                      if (logScroll.hasClients) {
                        logScroll.jumpTo(logScroll
                            .position.maxScrollExtent);
                      }
                    });
                    if (lines.isEmpty) {
                      return const Center(
                        child: Text('Sin logs todavia.',
                            style: TextStyle(
                                color: _C.off, fontSize: 13)),
                      );
                    }
                    return ListView.builder(
                      controller: logScroll,
                      padding: const EdgeInsets.fromLTRB(
                          16, 10, 16, 16),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 1),
                        child: Text(lines[i],
                            style: _mono.copyWith(
                                color: _C.textLo)),
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

  // ═══════════════════════════════════════════════════════════════════
  //  BOTON ENTORNO IA
  // ═══════════════════════════════════════════════════════════════════

  Widget _envStatusButton(StateSetter setS) {
    final checking = _svc.envChecking.value;
    final setupRunning = _svc.envSetupRunning.value;
    final ready = _svc.envReady.value;
    final status = _svc.envStatus.value;
    final isWorking = checking || setupRunning;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ready ? _C.ok.withOpacity(0.08) : _C.cardAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ready
              ? _C.ok.withOpacity(0.4)
              : isWorking
                  ? _C.accent.withOpacity(0.4)
                  : _C.border,
        ),
      ),
      child: InkWell(
        onTap: isWorking
            ? null
            : () async {
                if (ready) {
                  await _svc.checkAgentEnv();
                  setS(() {});
                } else {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: _C.card,
                      title: const Text('Preparar entorno IA',
                          style: TextStyle(
                              color: _C.textHi, fontSize: 16)),
                      content: const Text(
                        'Se instalara Python3, smolagents y las herramientas necesarias.\n\n'
                        'Requiere conexion a internet.\n'
                        'Duracion estimada: ~10 minutos.',
                        style: TextStyle(
                            color: _C.textLo,
                            fontSize: 13,
                            height: 1.5),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx, false),
                          child: const Text('Cancelar',
                              style:
                                  TextStyle(color: _C.textLo)),
                        ),
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx, true),
                          child: const Text('Iniciar',
                              style: TextStyle(
                                  color: _C.accent)),
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
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: ready
                    ? _C.ok.withOpacity(0.15)
                    : isWorking
                        ? _C.accent.withOpacity(0.15)
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
                        ready
                            ? Icons.check_rounded
                            : Icons.build_outlined,
                        size: 18,
                        color: ready ? _C.ok : _C.warn,
                      ),
              ),
            ),
            const SizedBox(width: 12),
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
            if (!isWorking)
              IconButton(
                tooltip: ready
                    ? 'Verificar de nuevo'
                    : 'Preparar entorno',
                onPressed: () async {
                  if (ready) {
                    await _svc.checkAgentEnv();
                  } else {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: _C.card,
                        title: const Text(
                            'Preparar entorno IA',
                            style: TextStyle(
                                color: _C.textHi,
                                fontSize: 16)),
                        content: const Text(
                          'Se instalara Python3, smolagents y las herramientas necesarias.\n\n'
                          'Requiere conexion a internet.\n'
                          'Duracion estimada: ~10 minutos.',
                          style: TextStyle(
                              color: _C.textLo,
                              fontSize: 13,
                              height: 1.5),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(ctx, false),
                            child: const Text('Cancelar',
                                style: TextStyle(
                                    color: _C.textLo)),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(ctx, true),
                            child: const Text('Iniciar',
                                style: TextStyle(
                                    color: _C.accent)),
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
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final logScroll = ScrollController();
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(18, 14, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.build_outlined,
                        size: 18, color: _C.textLo),
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
                            style: TextStyle(
                                color: _C.err, fontSize: 12)),
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
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: _svc.envLog,
                  builder: (_, lines, __) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) {
                      if (logScroll.hasClients) {
                        logScroll.jumpTo(logScroll
                            .position.maxScrollExtent);
                      }
                    });
                    if (lines.isEmpty) {
                      return const Center(
                        child: Text('Esperando inicio...',
                            style: TextStyle(
                                color: _C.off, fontSize: 13)),
                      );
                    }
                    return ListView.builder(
                      controller: logScroll,
                      padding: const EdgeInsets.fromLTRB(
                          16, 10, 16, 16),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 1),
                        child: Text(lines[i],
                            style: _mono.copyWith(
                                color: _C.textLo)),
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

  // ═══════════════════════════════════════════════════════════════════
  //  AJUSTES
  // ═══════════════════════════════════════════════════════════════════

  void _showSettingsSheet() {
    final baseUrlCtrl =
        TextEditingController(text: _svc.remoteBaseUrl);
    final modelCtrl =
        TextEditingController(text: _svc.remoteModel);
    final keyCtrl =
        TextEditingController(text: _svc.remoteApiKey);
    bool obscureKey = true;

    double temp = _svc.temp;
    double topP = _svc.topP;
    int topK = _svc.topK;
    final agentPortCtrl =
        TextEditingController(text: _svc.agentPort.toString());

    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(16)),
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
                      padding: const EdgeInsets.fromLTRB(
                          18, 14, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.tune,
                              size: 19, color: _C.textLo),
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
                              agentPortCtrl.text =
                                  _svc.agentPort.toString();
                            }),
                            child: const Text('Restablecer',
                                style: TextStyle(
                                    color: _C.textLo,
                                    fontSize: 12.5)),
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
                        padding: const EdgeInsets.fromLTRB(
                            16, 16, 16, 24),
                        children: [
                          _envStatusButton(setS),
                          const SizedBox(height: 8),
                          if (_svc.envSetupRunning.value ||
                              _svc.envLog.value.isNotEmpty)
                            Center(
                              child: TextButton.icon(
                                onPressed: _showEnvSetupLogs,
                                icon: const Icon(
                                    Icons.article_outlined,
                                    size: 14,
                                    color: _C.accent),
                                label: const Text(
                                    'Ver logs del setup',
                                    style: TextStyle(
                                        color: _C.accent,
                                        fontSize: 12)),
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
                              _sourceChip(
                                  'gpu_local',
                                  'GPU Local',
                                  setS,
                                  baseUrlCtrl,
                                  modelCtrl),
                              _sourceChip(
                                  'custom',
                                  'Personalizado',
                                  setS,
                                  baseUrlCtrl,
                                  modelCtrl),
                            ],
                          ),
                          const SizedBox(height: 18),

                          if (_selSource == 'gpu_local') ...[
                            _gpuLocalPanel(setS),
                            const SizedBox(height: 18),
                          ],

                          if (_selSource == 'custom') ...[
                            _cfgLabel('URL base'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: baseUrlCtrl,
                              style: const TextStyle(
                                  color: _C.textHi,
                                  fontSize: 13,
                                  fontFamily: 'monospace'),
                              decoration: _fieldDeco(
                                  hint: 'https://.../v1'),
                            ),
                            const SizedBox(height: 14),
                            _cfgLabel('Modelo'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: modelCtrl,
                              style: const TextStyle(
                                  color: _C.textHi,
                                  fontSize: 13,
                                  fontFamily: 'monospace'),
                              decoration: _fieldDeco(
                                  hint: 'nombre-del-modelo'),
                            ),
                            const SizedBox(height: 14),
                            _cfgLabel('API key'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: keyCtrl,
                              obscureText: obscureKey,
                              style: const TextStyle(
                                  color: _C.textHi,
                                  fontSize: 13,
                                  fontFamily: 'monospace'),
                              decoration: _fieldDeco(
                                      hint: '(opcional)')
                                  .copyWith(
                                suffixIcon: IconButton(
                                  icon: Icon(
                                      obscureKey
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                      size: 18,
                                      color: _C.off),
                                  onPressed: () => setS(() =>
                                      obscureKey = !obscureKey),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'La key se guarda solo en la app '
                              '(no en el rootfs) y se inyecta al '
                              'agente como variable de entorno efimera.',
                              style: TextStyle(
                                  color: _C.off,
                                  fontSize: 11,
                                  height: 1.4),
                            ),
                            const SizedBox(height: 18),
                          ],

                          const Divider(color: _C.border),
                          const SizedBox(height: 14),
                          _cfgLabel(
                              'Parametros de inferencia'),
                          const SizedBox(height: 10),
                          _cfgSlider(
                              'Temperature',
                              temp,
                              0.0,
                              2.0,
                              40,
                              temp.toStringAsFixed(2),
                              (v) => setS(() => temp = v)),
                          _cfgSlider(
                              'Top-p',
                              topP,
                              0.0,
                              1.0,
                              20,
                              topP.toStringAsFixed(2),
                              (v) => setS(() => topP = v)),
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
                                color: _C.textHi,
                                fontSize: 14,
                                fontFamily: 'monospace'),
                            decoration: _fieldDeco(),
                          ),
                          const SizedBox(height: 24),
                          _AnimatedActionButton(
                            label: 'Guardar configuracion',
                            icon: Icons.save_outlined,
                            width: double.infinity,
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
                              _svc.agentPort = int.tryParse(
                                      agentPortCtrl.text.trim()) ??
                                  _svc.agentPort;
                              await _svc.saveSettings();
                              final wasAgent = _svc.agentLaunched;
                              if (wasAgent) _svc.stopAgent();
                              if (mounted) setState(() {});
                              if (mounted) Navigator.pop(ctx);
                              _snack(
                                  'Ajustes guardados. Reinicia el agente para aplicar.');
                            },
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

  Widget _sourceChip(
      String id,
      String label,
      StateSetter setS,
      TextEditingController baseCtrl,
      TextEditingController modelCtrl) {
    final selected = id == _selSource;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      labelStyle: TextStyle(
          color: selected ? Colors.white : _C.textLo,
          fontSize: 12.5),
      backgroundColor: _C.card,
      selectedColor: _C.accent,
      side: BorderSide(
          color: selected ? _C.accent : _C.border),
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

  // ═══════════════════════════════════════════════════════════════════
  //  PANEL GPU LOCAL
  // ═══════════════════════════════════════════════════════════════════

  Widget _gpuLocalPanel(StateSetter setS) {
    return Container(
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
              const Icon(Icons.memory,
                  size: 16, color: _C.accent),
              const SizedBox(width: 8),
              const Text('GPU Local · MediaPipe',
                  style: TextStyle(
                      color: _C.textHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_svc.mpServerRunning)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: _C.ok.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6)),
                  child: const Text(':8090',
                      style: TextStyle(
                          color: _C.ok,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
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
                  border: Border.all(color: _C.border)),
              child: Text(
                'No hay modelos en:\n${_svc.mpModelsDir ?? "(carpeta de modelos)"}\n\n'
                'Copia un .task (ej: gemma3-1b-it-int4.task) y recarga.',
                style: const TextStyle(
                    color: _C.textLo,
                    fontSize: 11.5,
                    height: 1.45),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                  color: _C.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _C.border)),
              child: Column(
                children: _svc.mpModels.map((m) {
                  final p = m.path;
                  final name = p.split('/').last;
                  final selected = p == _svc.mpSelectedPath;
                  return InkWell(
                    onTap: _svc.mpLoaded
                        ? null
                        : () => setS(
                            () => _svc.mpSelectedPath = p),
                    child: Padding(
                      padding: const EdgeInsets.only(
                          left: 10, right: 4, top: 6, bottom: 6),
                      child: Row(
                        children: [
                          Icon(
                              selected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: selected
                                  ? _C.accent
                                  : _C.textLo),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(name,
                                style: TextStyle(
                                    color: selected
                                        ? _C.textHi
                                        : _C.textLo,
                                    fontSize: 12),
                                overflow: TextOverflow.ellipsis),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 16, color: _C.err),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
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
                icon: const Icon(Icons.file_download_outlined,
                    size: 15, color: _C.accent),
                label: const Text('Importar',
                    style: TextStyle(
                        color: _C.accent, fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: () async {
                  await _svc.scanMpModels();
                  if (mounted) setS(() {});
                },
                icon: const Icon(Icons.refresh,
                    size: 15, color: _C.textLo),
                label: const Text('Recargar',
                    style: TextStyle(
                        color: _C.textLo, fontSize: 12)),
              ),
              const Spacer(),
              const Text('Backend:',
                  style: TextStyle(
                      color: _C.textLo, fontSize: 11.5)),
              const SizedBox(width: 6),
              ToggleButtons(
                isSelected: [
                  _svc.mpUseGpu,
                  !_svc.mpUseGpu
                ],
                onPressed: _svc.mpLoaded
                    ? null
                    : (i) => setS(
                        () => _svc.mpUseGpu = i == 0),
                borderRadius: BorderRadius.circular(6),
                borderColor: _C.border,
                selectedBorderColor: _C.accent,
                fillColor: _C.accent,
                color: _C.textLo,
                selectedColor: Colors.white,
                constraints: const BoxConstraints(
                    minHeight: 28, minWidth: 44),
                children: const [
                  Text('GPU',
                      style: TextStyle(fontSize: 11)),
                  Text('CPU',
                      style: TextStyle(fontSize: 11))
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _AnimatedActionButton(
                  label: _svc.mpLoaded ? 'Cargado' : 'Cargar',
                  icon: _svc.mpLoaded ? Icons.check : Icons.bolt,
                  loading: _svc.mpLoading,
                  disabled: _svc.mpLoaded,
                  color: _svc.mpLoaded ? _C.card : _C.accent,
                  textColor: _svc.mpLoaded
                      ? _C.textLo
                      : Colors.white,
                  onPressed: () async {
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
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 14)),
                  onPressed: () async {
                    await _svc.unloadMpModel();
                    if (mounted) setS(() {});
                  },
                  child: const Text('Liberar',
                      style: TextStyle(fontSize: 12)),
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
                border: Border.all(color: _C.border)),
            child: Row(
              children: [
                Icon(
                    _svc.mpLoaded
                        ? Icons.check_circle
                        : Icons.info_outline,
                    size: 14,
                    color: _svc.mpLoaded ? _C.ok : _C.textLo),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_svc.mpStatus,
                      style: const TextStyle(
                          color: _C.textLo,
                          fontSize: 11.5,
                          height: 1.4)),
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
              style: const TextStyle(
                  color: _C.textHi, fontSize: 13),
              decoration: InputDecoration(
                filled: true,
                fillColor: _C.card,
                contentPadding: const EdgeInsets.all(10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: _C.border)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: _C.border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: _C.accent)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _AnimatedActionButton(
                    label: _svc.mpGenerating
                        ? 'Generando...'
                        : 'Probar',
                    icon: Icons.play_arrow_rounded,
                    loading: _svc.mpGenerating,
                    disabled:
                        !_svc.mpLoaded || _svc.mpGenerating,
                    onPressed: () async {
                      await _svc.generateMpTest(_mpPrompt.text);
                      if (mounted) setS(() {});
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _AnimatedActionButton(
                    label: _svc.mpServerRunning
                        ? 'Detener :8090'
                        : 'Iniciar :8090',
                    icon: _svc.mpServerRunning
                        ? Icons.stop
                        : Icons.play_arrow_rounded,
                    disabled: _svc.mpServerBusy,
                    color: _svc.mpServerRunning
                        ? _C.card
                        : _C.accent,
                    textColor: _svc.mpServerRunning
                        ? _C.textLo
                        : Colors.white,
                    onPressed: () async {
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _C.accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _C.accent.withOpacity(0.4))),
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
                    border: Border.all(color: _C.border)),
                child: SelectableText(_svc.mpOutput,
                    style: const TextStyle(
                        color: _C.textHi,
                        fontSize: 12.5,
                        height: 1.45)),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  HISTORIAL
  // ═══════════════════════════════════════════════════════════════════

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(18, 14, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.history,
                          size: 19, color: _C.textLo),
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
                  padding: const EdgeInsets.fromLTRB(
                      16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: _C.accent,
                              side: const BorderSide(
                                  color: _C.border),
                              padding:
                                  const EdgeInsets.symmetric(
                                      vertical: 11)),
                          icon: const Icon(Icons.save_outlined,
                              size: 17),
                          label: const Text('Guardar actual'),
                          onPressed: _ctrl.blocks.value.isEmpty
                              ? null
                              : () async {
                                  final name =
                                      await _promptName();
                                  if (name == null) return;
                                  await _ctrl.saveAs(name);
                                  setS(() {});
                                  _snack(
                                      'Conversacion guardada.');
                                },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: _C.textLo,
                              side: const BorderSide(
                                  color: _C.border),
                              padding:
                                  const EdgeInsets.symmetric(
                                      vertical: 11)),
                          icon: const Icon(
                              Icons.add_comment_outlined,
                              size: 17),
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
                    padding: const EdgeInsets.fromLTRB(
                        18, 8, 16, 6),
                    child: _cfgLabel('Guardadas'),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<SavedChat>>(
                    future: _ctrl.listSaved(),
                    builder: (_, snap) {
                      if (snap.connectionState !=
                          ConnectionState.done) {
                        return const Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _C.accent)),
                        );
                      }
                      final saved = snap.data ?? [];
                      if (saved.isEmpty) {
                        return const Center(
                          child: Text(
                              'No hay conversaciones guardadas.',
                              style: TextStyle(
                                  color: _C.off,
                                  fontSize: 13)),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                            16, 0, 16, 16),
                        itemCount: saved.length,
                        itemBuilder: (_, i) {
                          final sc = saved[i];
                          return Container(
                            margin: const EdgeInsets.only(
                                bottom: 8),
                            decoration: BoxDecoration(
                                color: _C.card,
                                borderRadius:
                                    BorderRadius.circular(10),
                                border: Border.all(
                                    color: _C.border)),
                            child: ListTile(
                              dense: true,
                              leading: const Icon(
                                  Icons.chat_bubble_outline,
                                  color: _C.textLo,
                                  size: 18),
                              title: Text(sc.name,
                                  style: const TextStyle(
                                      color: _C.textHi,
                                      fontSize: 13.5),
                                  overflow:
                                      TextOverflow.ellipsis),
                              subtitle: Text(sc.dateLabel,
                                  style: const TextStyle(
                                      color: _C.off,
                                      fontSize: 11.5)),
                              trailing: IconButton(
                                icon: const Icon(
                                    Icons.delete_outline,
                                    size: 19,
                                    color: _C.off),
                                onPressed: () async {
                                  await _ctrl
                                      .deleteSaved(sc.path);
                                  setS(() {});
                                },
                              ),
                              onTap: () async {
                                await _ctrl.loadSaved(sc.path);
                                if (mounted) setState(() {});
                                if (!mounted) return;
                                Navigator.pop(ctx);
                                _scrollToBottom();
                                _snack(
                                    'Conversacion cargada.');
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
            child: const Text('Cancelar',
                style: TextStyle(color: _C.textLo))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Guardar',
                style: TextStyle(color: _C.accent))),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  HELPERS DE UI
  // ═══════════════════════════════════════════════════════════════════

  Widget _cfgLabel(String t) => Text(
        t.toUpperCase(),
        style: const TextStyle(
            color: _C.textLo,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6),
      );

  Widget _cfgStepper(String label, int value, int min, int max,
      int step, ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: _C.textHi, fontSize: 14))),
        IconButton(
          onPressed: value > min
              ? () => onChanged(
                  (value - step).clamp(min, max))
              : null,
          icon: const Icon(Icons.remove_circle_outline,
              size: 22),
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
              ? () => onChanged(
                  (value + step).clamp(min, max))
              : null,
          icon: const Icon(Icons.add_circle_outline,
              size: 22),
          color: _C.accent,
          disabledColor: _C.off,
        ),
      ],
    );
  }

  Widget _cfgSlider(
      String label,
      double value,
      double min,
      double max,
      int divisions,
      String valueLabel,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(
                    color: _C.textHi, fontSize: 14)),
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
            overlayColor: _C.accent.withOpacity(0.15),
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
          borderSide: const BorderSide(color: _C.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _C.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _C.accent)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  WIDGETS AUXILIARES
// ═══════════════════════════════════════════════════════════════════

class _StatusDot extends StatelessWidget {
  final bool failed;
  final bool starting;
  final bool active;
  const _StatusDot(
      {this.failed = false,
      this.starting = false,
      this.active = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: failed
            ? _C.err
            : (starting
                ? _C.warn
                : (active ? _C.ok : _C.off)),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  final _QuickPrompt prompt;
  final VoidCallback onTap;
  const _PromptCard({required this.prompt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _C.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _C.border),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: prompt.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(prompt.icon,
                  size: 16, color: prompt.color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(prompt.title,
                      style: const TextStyle(
                          color: _C.textHi,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(prompt.description,
                      style: const TextStyle(
                          color: _C.textLo,
                          fontSize: 10.5,
                          height: 1.3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Fila de menu overflow (icono + texto) con la paleta XTR.
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _C.textLo),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: _C.textHi, fontSize: 13.5)),
      ],
    );
  }
}

// ============================================================
// Modo Autonomo — panel integrado (antes agent_autonomous.dart)
// ============================================================

/// Paleta obligatoria del proyecto XTR.
class _AC {
  static const Color bg = Color(0xFF1C1C1E);
  static const Color card = Color(0xFF2C2C2E);
  static const Color cardAlt = Color(0xFF242426);
  static const Color border = Color(0xFF3A3A3C);
  static const Color textHi = Color(0xFFEAEAEC);
  static const Color textLo = Color(0xFF9A9AA0);
  static const Color ok = Color(0xFF34C759);
  static const Color off = Color(0xFF6B6B70);
  static const Color err = Color(0xFFFF453A);
  static const Color accent = Color(0xFF5E9BD6);
  static const Color warn = Color(0xFFFF9F0A);
  static const Color purple = Color(0xFFBF5AF2);
  static const Color teal = Color(0xFF5AC8FA);
}

/// Panel autónomo: objetivos, progreso en vivo, historial y memoria.
class AgentAutonomousPanel extends StatefulWidget {
  const AgentAutonomousPanel({super.key});

  /// URL base del agent-server (dentro del contenedor proot).
  static const String baseUrl = 'http://127.0.0.1:8765';

  @override
  State<AgentAutonomousPanel> createState() => _AgentAutonomousPanelState();
}

class _AgentAutonomousPanelState extends State<AgentAutonomousPanel> {
  bool _autonomousOn = false;
  bool _launching = false;
  bool _serverDown = false;

  String? _goalId;
  String _status = 'idle';
  int _currentStep = 0;
  int _maxSteps = 0;
  List<Map<String, dynamic>> _steps = <Map<String, dynamic>>[];
  String _result = '';

  List<Map<String, dynamic>> _goals = <Map<String, dynamic>>[];

  Timer? _pollTimer;
  final TextEditingController _goalCtrl = TextEditingController();
  final ScrollController _resultScroll = ScrollController();

  static const Duration _httpTimeout = Duration(seconds: 8);
  static const Duration _pollInterval = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _refreshGoals();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _goalCtrl.dispose();
    _resultScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('${AgentAutonomousPanel.baseUrl}$path')
          .replace(queryParameters: q);

  Future<Map<String, dynamic>?> _getJson(String path,
      [Map<String, String>? q]) async {
    try {
      final http.Response res =
          await http.get(_u(path, q)).timeout(_httpTimeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final dynamic body = json.decode(res.body);
        _serverDown = false;
        if (body is Map<String, dynamic>) return body;
      }
      return null;
    } catch (_) {
      _serverDown = true;
      return null;
    }
  }

  Future<Map<String, dynamic>?> _postJson(
      String path, Map<String, dynamic> payload) async {
    try {
      final http.Response res = await http
          .post(
            _u(path),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(_httpTimeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final dynamic body = json.decode(res.body);
        _serverDown = false;
        if (body is Map<String, dynamic>) return body;
      }
      return null;
    } catch (_) {
      _serverDown = true;
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Acciones
  // ---------------------------------------------------------------------------

  Future<void> _launchGoal() async {
    final String goal = _goalCtrl.text.trim();
    if (goal.isEmpty || _launching) return;

    setState(() {
      _launching = true;
      _status = 'running';
      _currentStep = 0;
      _maxSteps = 0;
      _steps = <Map<String, dynamic>>[];
      _result = '';
      _goalId = null;
    });

    final Map<String, dynamic>? resp =
        await _postJson('/goal', <String, dynamic>{'goal': goal});

    if (!mounted) return;
    if (resp == null) {
      setState(() {
        _launching = false;
        _status = 'idle';
      });
      _showServerDown();
      return;
    }

    setState(() {
      _launching = false;
      _goalId = resp['goal_id']?.toString();
      _status = resp['status']?.toString() ?? 'running';
    });

    if (_status == 'running') {
      _startPolling();
    }
    _refreshGoals();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollStatus());
    _pollStatus();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollStatus() async {
    final String? id = _goalId;
    if (id == null) return;

    final Map<String, dynamic>? resp =
        await _getJson('/goal/status', <String, String>{'goal_id': id});
    if (!mounted) return;

    if (resp == null) {
      // No abortamos: puede ser un fallo transitorio.
      setState(() => _serverDown = true);
      return;
    }

    final String status = resp['status']?.toString() ?? 'running';
    final List<dynamic> rawSteps =
        (resp['steps'] is List) ? resp['steps'] as List<dynamic> : <dynamic>[];

    setState(() {
      _status = status;
      _currentStep =
          (resp['current_step'] is num) ? (resp['current_step'] as num).toInt() : rawSteps.length;
      _maxSteps =
          (resp['max_steps'] is num) ? (resp['max_steps'] as num).toInt() : 0;
      _steps = rawSteps
          .whereType<Map>()
          .map((Map e) => e.cast<String, dynamic>())
          .toList();
      _result = resp['result']?.toString() ?? '';
      _serverDown = false;
    });

    if (status != 'running') {
      _stopPolling();
      _refreshGoals();
    }
  }

  Future<void> _refreshGoals() async {
    final Map<String, dynamic>? resp = await _getJson('/goal/list');
    if (!mounted) return;
    if (resp == null) {
      setState(() => _serverDown = true);
      return;
    }
    final List<dynamic> raw =
        (resp['goals'] is List) ? resp['goals'] as List<dynamic> : <dynamic>[];
    setState(() {
      _goals = raw
          .whereType<Map>()
          .map((Map e) => e.cast<String, dynamic>())
          .toList();
      _serverDown = false;
    });
  }

  Future<void> _showMemory() async {
    final Map<String, dynamic>? resp = await _getJson('/memory');
    if (!mounted) return;

    if (resp == null) {
      _showServerDown();
      return;
    }

    final List<dynamic> episodes = (resp['episodes'] is List)
        ? resp['episodes'] as List<dynamic>
        : (resp is List ? resp as List<dynamic> : <dynamic>[]);

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: _AC.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Memoria del agente',
            style: TextStyle(color: _AC.textHi, fontSize: 16)),
        content: SizedBox(
          width: 420,
          height: 360,
          child: episodes.isEmpty
              ? const Center(
                  child: Text('Sin episodios aún.',
                      style: TextStyle(color: _AC.textLo)))
              : ListView.separated(
                  itemCount: episodes.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: _AC.border, height: 1),
                  itemBuilder: (BuildContext c, int i) {
                    final dynamic ep = episodes[i];
                    final String text = ep is Map
                        ? (ep['summary'] ?? ep['text'] ?? ep.toString())
                            .toString()
                        : ep.toString();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(text,
                          style: const TextStyle(
                              color: _AC.textHi, fontSize: 13)),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar',
                style: TextStyle(color: _AC.accent)),
          ),
        ],
      ),
    );
  }

  void _showServerDown() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _AC.card,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: const Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: _AC.err, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Agente no disponible — arráncalo con el botón ▶',
                style: TextStyle(color: _AC.textHi),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Color _statusColor(String status) {
    switch (status) {
      case 'running':
        return _AC.accent;
      case 'done':
        return _AC.ok;
      case 'failed':
        return _AC.err;
      case 'timeout':
        return _AC.warn;
      default:
        return _AC.off;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _AC.bg,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _buildHeader(),
          if (_serverDown) _buildServerBanner(),
          const SizedBox(height: 16),
          _buildGoalInput(),
          const SizedBox(height: 16),
          _buildProgressPanel(),
          const SizedBox(height: 16),
          _buildGoalsList(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _AC.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _AC.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.smart_toy_outlined,
              color: _autonomousOn ? _AC.purple : _AC.off,
              size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Modo Autónomo',
                    style: TextStyle(
                        color: _AC.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  _autonomousOn
                      ? 'El agente puede ejecutar objetivos por sí solo'
                      : 'Desactivado',
                  style:
                      const TextStyle(color: _AC.textLo, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: _autonomousOn,
            onChanged: (bool v) => setState(() => _autonomousOn = v),
            activeThumbColor: _AC.purple,
            activeTrackColor: _AC.purple.withOpacity(0.4),
            inactiveThumbColor: _AC.off,
            inactiveTrackColor: _AC.cardAlt,
          ),
        ],
      ),
    );
  }

  Widget _buildServerBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _AC.cardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _AC.err.withOpacity(0.5)),
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.cloud_off, color: _AC.err, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Agente no disponible — arráncalo con el botón ▶',
              style: TextStyle(color: _AC.textHi, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGoalInput() {
    final bool enabled = _autonomousOn;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _AC.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _AC.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('Objetivo',
                style: TextStyle(
                    color: _AC.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(
              controller: _goalCtrl,
              enabled: enabled,
              maxLines: 4,
              minLines: 3,
              style: const TextStyle(color: _AC.textHi, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Describe qué debe hacer el agente…',
                hintStyle:
                    const TextStyle(color: _AC.textLo, fontSize: 14),
                filled: true,
                fillColor: _AC.cardAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _AC.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _AC.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _AC.accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: (enabled && !_launching) ? _launchGoal : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _AC.purple,
                  disabledBackgroundColor: _AC.cardAlt,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: _launching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.rocket_launch, size: 18),
                label: Text(_launching ? 'Lanzando…' : 'Lanzar'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressPanel() {
    final bool running = _status == 'running';
    final double progress = (_maxSteps > 0)
        ? (_currentStep / _maxSteps).clamp(0.0, 1.0)
        : (running ? -1 : 0).toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _AC.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _AC.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('Progreso',
                  style: TextStyle(
                      color: _AC.textHi,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              _statusChip(_status),
              const SizedBox(width: 8),
              if (running)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _AC.accent),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: progress >= 0
                ? LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: _AC.cardAlt,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        _AC.accent),
                  )
                : const LinearProgressIndicator(
                    minHeight: 8,
                    backgroundColor: _AC.cardAlt,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(_AC.accent),
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            _maxSteps > 0
                ? 'Paso $_currentStep de $_maxSteps'
                : (_steps.isEmpty ? 'Sin pasos' : '${_steps.length} pasos'),
            style: const TextStyle(color: _AC.textLo, fontSize: 12),
          ),
          if (_steps.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            const Divider(color: _AC.border, height: 1),
            const SizedBox(height: 10),
            for (int i = 0; i < _steps.length; i++) _buildStepRow(i, _steps[i]),
          ],
          if (!running && _result.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            const Divider(color: _AC.border, height: 1),
            const SizedBox(height: 10),
            const Text('Resultado',
                style: TextStyle(
                    color: _AC.textHi,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _AC.cardAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _AC.border),
              ),
              child: Scrollbar(
                controller: _resultScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _resultScroll,
                  child: SelectableText(
                    _result,
                    style: const TextStyle(
                        color: _AC.textHi,
                        fontSize: 12.5,
                        fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStepRow(int index, Map<String, dynamic> step) {
    final bool success = step['success'] == true ||
        step['ok'] == true ||
        step['status'] == 'ok';
    final String tool = (step['tool'] ?? step['action'] ?? 'paso ${index + 1}')
        .toString();
    final String summary =
        (step['summary'] ?? step['message'] ?? step['output'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            success ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: success ? _AC.ok : _AC.err,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(tool,
                    style: const TextStyle(
                        color: _AC.teal,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                if (summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: _AC.textLo, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String status) {
    final Color c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.6)),
      ),
      child: Text(status,
          style: TextStyle(
              color: c, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildGoalsList() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _AC.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _AC.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('Objetivos anteriores',
                  style: TextStyle(
                      color: _AC.textHi,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _showMemory,
                icon: const Icon(Icons.psychology,
                    size: 16, color: _AC.purple),
                label: const Text('Ver memoria',
                    style:
                        TextStyle(color: _AC.purple, fontSize: 12)),
              ),
              IconButton(
                onPressed: _refreshGoals,
                icon: const Icon(Icons.refresh,
                    size: 18, color: _AC.textLo),
                tooltip: 'Actualizar',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_goals.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Todavía no hay objetivos.',
                  style: TextStyle(color: _AC.textLo, fontSize: 12)),
            )
          else
            for (final Map<String, dynamic> g in _goals) _buildGoalRow(g),
        ],
      ),
    );
  }

  Widget _buildGoalRow(Map<String, dynamic> goal) {
    final String id = (goal['goal_id'] ?? goal['id'] ?? '').toString();
    final String text =
        (goal['goal'] ?? goal['title'] ?? goal['text'] ?? '').toString();
    final String status = (goal['status'] ?? 'unknown').toString();

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: id.isEmpty
          ? null
          : () {
              setState(() {
                _goalId = id;
                _status = status;
                _steps = <Map<String, dynamic>>[];
                _result = '';
                _currentStep = 0;
                _maxSteps = 0;
              });
              if (status == 'running') {
                _startPolling();
              } else {
                _pollStatus();
              }
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _AC.cardAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _AC.border),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                text.isEmpty ? id : text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: _AC.textHi, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            _statusChip(status),
          ],
        ),
      ),
    );
  }
}
