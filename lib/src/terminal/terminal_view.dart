import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:xterm/xterm.dart';
import '../container/container_manager.dart';
import 'terminal_keybar.dart';
import 'terminal_session.dart';
import 'keybar_config.dart';
import 'keybar_settings_screen.dart';
import '../agent/agent_dashboard.dart';
import '../agent/agent_services.dart';
import 'clipboard_vault.dart';
import 'selection_overlay_termux.dart';
import '../ssh/ssh_host.dart';
import '../ssh/ssh_hosts_service.dart';
import '../ssh/hosts_screen.dart';
import '../sftp/sftp_browser_screen.dart';
import '../sftp/sftp_favorites_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  final ContainerManager _manager = ContainerManager();
  final List<TerminalSession> _sessions = [];
  int _activeIndex = 0;
  static const int _maxSessions = 5;

  /// Versión visible en la barra de título. La actualiza el instalador de
  /// cada release (sed sobre este literal) — no editar a mano.
  static const String _appVersion = 'v14.5';

  List<KeyConfigItem> _keybarConfig = KeyCatalog.defaultConfig;

  final List<String> _logLines = [];
  double? _progress = 0.0;
  bool _spinning = false;
  bool _booting = true;
  bool _showAgent = false; // Arranca en terminal (menú lc-menu)
  String? _error;
  final Map<int, FocusNode> _focusNodes = {};
  final Map<int, GlobalKey<TerminalViewState>> _viewKeys = {};

  /// Sesiones SSH con el panel SFTP montado / visible. Se guarda el OBJETO
  /// sesión (no el índice) por la misma razón que sourceHost: cerrar una
  /// pestaña desplaza índices y un mapa por índice apuntaría mal.
  final Set<TerminalSession> _sftpOpened = {};
  final Set<TerminalSession> _sftpOpen = {};

  double _fontSize = 12.0;
  static const double _minFont = 8.0;
  static const double _maxFont = 28.0;

  TerminalSession get _active => _sessions[_activeIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_showAgent) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          _focusNodes[_activeIndex]?.requestFocus();
          SystemChannels.textInput.invokeMethod('TextInput.show');
        }
      });
    }
  }

  void _appendLog(String line, {bool spinning = false, double? progress}) {
    if (!mounted) return;
    setState(() {
      _logLines.add(line);
      _spinning = spinning;
      if (progress != null) _progress = progress;
    });
  }

  Future<void> _boot() async {
    try {
      // Carga la configuración del teclado guardada
      _keybarConfig = await KeybarConfig.load();
      await _manager.initContainer(log: _appendLog);
      if (_manager.isReady) {
        final svc = AgentServices();
        svc.startAgent();
        svc.startCron();
        await ClipboardVault.instance.loadFrom(_manager.rootfsPath!);
        await SshHostsService.instance.loadFrom(_manager.rootfsPath!);
        await SftpFavoritesService.instance.loadFrom(_manager.rootfsPath!);
      }
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      _addSession(initial: true);
      setState(() => _booting = false);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) {
          if (mounted) _startActiveSession();
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _booting = false;
      });
    }
  }

  void _addSession({bool initial = false}) {
    if (_sessions.length >= _maxSessions) {
      _toast('Máximo $_maxSessions sesiones');
      return;
    }
    final n = _sessions.length + 1;
    final session = TerminalSession('Sesión $n');
    _sessions.add(session);
    if (!initial) {
      setState(() => _activeIndex = _sessions.length - 1);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) {
          if (mounted) _startActiveSession();
        });
      });
    }
  }

  void _startActiveSession() {
    final s = _active;
    if (s.isStarted) return;
    s.start(columns: s.terminal.viewWidth, rows: s.terminal.viewHeight);
  }

  void _connectToHost(SshHost host) {
    if (_sessions.length >= _maxSessions) {
      _toast('Máximo $_maxSessions sesiones');
      return;
    }
    final session = TerminalSession(host.name, customCommand: host.toSshCommand(), sourceHost: host);
    _sessions.add(session);
    setState(() {
      _activeIndex = _sessions.length - 1;
      _showAgent = false;
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.endOfFrame.then((_) {
        if (mounted) _startActiveSession();
      });
    });
  }

  /// Alterna shell <-> explorador SFTP del mismo host DENTRO de la sesión
  /// SSH. El panel se crea perezoso la primera vez (entonces conecta) y se
  /// queda montado en el árbol: conserva carpeta, scroll y selección entre
  /// cambios. La shell sigue viva debajo (Offstage) y el circuito se cierra
  /// con onOpenTerminal, que simplemente vuelve a mostrar la terminal.
  void _toggleSftp(TerminalSession s) {
    if (s.sourceHost == null) return;
    setState(() {
      if (_sftpOpen.remove(s)) return; // estaba abierto -> volver a la shell
      _sftpOpened.add(s);              // primera vez: montar el panel
      _sftpOpen.add(s);
    });
  }

  void _openHosts() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HostsScreen(
        rootfsPath: _manager.rootfsPath,
        onConnect: (host) {
          Navigator.of(context).pop();
          _connectToHost(host);
        },
        onOpenTerminalFromSftp: (host) {
          // Se viene de mas adentro (explorador SFTP dentro de Hosts SSH),
          // asi que hay que cerrar dos pantallas, no una. popUntil hasta la
          // raiz es mas robusto que contar pops a mano.
          Navigator.of(context).popUntil((r) => r.isFirst);
          _connectToHost(host);
        },
      ),
    ));
  }

  void _switchTo(int index) {
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.endOfFrame.then((_) {
        if (mounted) _startActiveSession();
      });
    });
  }

  void _closeSession(int index) {
    if (_sessions.length == 1) {
      _toast('No puedes cerrar la última sesión');
      return;
    }
    final s = _sessions[index];
    _sftpOpen.remove(s);
    _sftpOpened.remove(s);
    s.dispose();
    setState(() {
      _sessions.removeAt(index);
      if (_activeIndex >= _sessions.length) {
        _activeIndex = _sessions.length - 1;
      }
    });
  }


  void _changeFont(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont);
    });
  }

  void _copySelection() {
    final sel = _active.controller.selection;
    if (sel != null) {
      final text = _active.terminal.buffer.getText(sel);
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
        _active.controller.clearSelection();
        _toast('Copiado al portapapeles');
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _active.terminal.textInput(text);
    }
  }

  /// Selecciona todo lo VISIBLE ahora mismo (el viewport), no todo el
  /// historial — para eso ya esta "Sesion completa" en el Portapapeles.
  void _selectAll() {
    final buf = _active.terminal.buffer;
    final topAbsolute = (buf.height - buf.viewHeight - buf.scrollBack)
        .clamp(0, buf.height - 1)
        .toInt();
    final bottomAbsolute = (topAbsolute + buf.viewHeight - 1)
        .clamp(0, buf.height - 1)
        .toInt();
    final base = buf.createAnchor(0, topAbsolute);
    final extent = buf.createAnchor(buf.viewWidth - 1, bottomAbsolute);
    _active.controller.setSelection(base, extent);
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
      );
    }
  }

  void _openKeybarSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => KeybarSettingsScreen(
          initial: _keybarConfig,
          onChanged: (newConfig) {
            setState(() => _keybarConfig = List.from(newConfig));
          },
        ),
      ),
    );
  }

  void _showSessions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._sessions.asMap().entries.map((e) {
              final i = e.key;
              final s = e.value;
              final active = i == _activeIndex;
              return ListTile(
                dense: true,
                leading: Icon(
                  s.sourceHost != null ? Icons.dns_rounded : Icons.computer,
                  size: 20,
                  color: s.sourceHost != null ? Colors.lightBlueAccent : Colors.tealAccent,
                ),
                title: Text(s.name, style: TextStyle(color: active ? Colors.white : Colors.white70)),
                subtitle: Text(
                  s.sourceHost != null ? s.sourceHost!.name : 'Sesión local (Debian)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (active) const Icon(Icons.check, color: Colors.greenAccent, size: 20),
                    if (_sessions.length > 1)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                        tooltip: 'Cerrar sesión',
                        onPressed: () { Navigator.pop(ctx); _closeSession(i); },
                      ),
                  ],
                ),
                onTap: () { Navigator.pop(ctx); _switchTo(i); },
              );
            }),
            const Divider(color: Colors.white24),
            if (_sessions.length < _maxSessions)
              ListTile(
                dense: true,
                leading: const Icon(Icons.add, color: Colors.greenAccent, size: 20),
                title: const Text('Nueva sesión', style: TextStyle(color: Colors.white)),
                onTap: () { Navigator.pop(ctx); _addSession(); },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.restart_alt, color: Colors.amberAccent, size: 20),
              title: const Text('Reiniciar sesión actual', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _active.restart(columns: _active.terminal.viewWidth, rows: _active.terminal.viewHeight);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.keyboard, color: Colors.greenAccent),
              title: const Text('Configurar teclado', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Mostrar, ocultar y reordenar teclas', style: TextStyle(color: Colors.white54)),
              onTap: () { Navigator.pop(ctx); _openKeybarSettings(); },
            ),
            ListTile(
              leading: const Icon(Icons.format_size, color: Colors.greenAccent),
              title: const Text('Tamaño de fuente', style: TextStyle(color: Colors.white)),
              subtitle: Text('${_fontSize.toInt()} pt', style: const TextStyle(color: Colors.white54)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove, color: Colors.white),
                    tooltip: 'Reducir fuente',
                    onPressed: () { _changeFont(-1); Navigator.pop(ctx); _showSettings(); },
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, color: Colors.white),
                    tooltip: 'Aumentar fuente',
                    onPressed: () { _changeFont(1); Navigator.pop(ctx); _showSettings(); },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  Color _lineColor(String line) {
    if (line.contains('[ OK ]')) return Colors.greenAccent;
    if (line.contains('[ .. ]')) return Colors.amberAccent;
    if (line.contains('[ !! ]')) return Colors.orangeAccent;
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Text('ERROR:\n$_error', style: const TextStyle(color: Colors.red, fontFamily: 'monospace')),
            ),
          ),
        ),
      );
    }

    if (_booting) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LinuxContainer · arranque', style: TextStyle(color:
Colors.white38, fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: _logLines.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        _logLines[i],
                        style: TextStyle(color: _lineColor(_logLines[i]), fontFamily: 'monospace', fontSize: 13, height: 1.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _spinning ? null : _progress, backgroundColor: Colors.white10, color: Colors.greenAccent),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    }

    // El agente y la terminal nunca se muestran a la vez: pantalla completa
    // para cada uno, conmutados por un botón. Así el input del agente tiene
    // todo el espacio y el teclado no se solapa.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _showAgent ? _agentView() : _terminalView(),
      ),
    );
  }

  Widget _agentView() {
    return AgentDashboard(
      // El botón de "ocultar" del dashboard ahora lleva a la terminal.
      onClose: () => setState(() => _showAgent = false),
    );
  }

  Widget _terminalView() {
    return Column(
      children: [
        // Barra superior: navegación + acciones principales. Hosts SSH/SFTP
        // siempre visibles (lo más usado); el resto vive en hojas: tocar el
        // título abre las sesiones y ⋮ del keybar abre ajustes.
        Container(
          color: const Color(0xFF1A1A1A),
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Agente IA',
                onPressed: () => setState(() => _showAgent = true),
                icon: const Icon(Icons.psychology, color: Colors.lightBlueAccent, size: 22),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _showSessions,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(text: 'XTR Terminal '),
                              const TextSpan(
                                text: _appVersion,
                                style: TextStyle(color: Colors.white38),
                              ),
                              if (_sessions.length > 1)
                                TextSpan(
                                  text: '  ·  ${_active.name} ${_activeIndex + 1}/${_sessions.length}',
                                  style: const TextStyle(color: Colors.white38),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white38),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Hosts SSH / SFTP',
                onPressed: _openHosts,
                icon: const Icon(Icons.dns_rounded, color: Colors.lightBlueAccent, size: 22),
              ),
              if (_active.sourceHost != null)
                IconButton(
                  tooltip: _sftpOpen.contains(_active)
                      ? 'Volver a la shell'
                      : 'SFTP de este host',
                  onPressed: () => _toggleSftp(_active),
                  icon: Icon(
                    _sftpOpen.contains(_active) ? Icons.terminal : Icons.folder_open,
                    color: Colors.amberAccent,
                    size: 22,
                  ),
                ),
              if (_sessions.length < _maxSessions)
                IconButton(
                  tooltip: 'Nueva sesión',
                  onPressed: _addSession,
                  icon: const Icon(Icons.add, color: Colors.greenAccent, size: 22),
                ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _activeIndex,
            children: _sessions.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              final focusNode = _focusNodes.putIfAbsent(i, () => FocusNode());
              final viewKey = _viewKeys.putIfAbsent(i, () => GlobalKey<TerminalViewState>());
              // Seleccion estilo Termux: el long-press nativo de xterm
              // selecciona la palabra y el overlay dibuja asas arrastrables
              // + barra Copiar/Pegar/Todo. La geometria celda<->pixel la da
              // el propio paquete (renderTerminal.getOffset/getCellOffset);
              // no hace falta calibracion (onTapUp esta muerto en xterm
              // 4.0.0: por eso el sistema anterior nunca dibujo las asas).
              final terminalPane = TermuxSelectionOverlay(
                terminal: s.terminal,
                controller: s.controller,
                terminalViewKey: viewKey,
                scrollController: s.scrollController,
                onCopy: _copySelection,
                onPaste: _paste,
                onSelectAll: _selectAll,
                child: TerminalView(
                  s.terminal,
                  key: viewKey,
                  controller: s.controller,
                  focusNode: focusNode,
                  autofocus: true,
                  backgroundOpacity: 1.0,
                  deleteDetection: true,
                  keyboardType: TextInputType.visiblePassword,
                  scrollController: s.scrollController,
                  textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace'),
                ),
              );

              if (s.sourceHost == null) return terminalPane;
              final sftpOpen = _sftpOpen.contains(s);
              return Stack(
                children: [
                  // La terminal no se desmonta nunca: solo se oculta, y su
                  // PTY y su scrollback siguen vivos mientras miras SFTP.
                  Offstage(offstage: sftpOpen, child: terminalPane),
                  if (_sftpOpened.contains(s))
                    Offstage(
                      offstage: !sftpOpen,
                      child: SftpBrowserScreen(
                        host: s.sourceHost!,
                        rootfsPath: _manager.rootfsPath!,
                        embedded: true,
                        onOpenTerminal: (_) =>
                            setState(() => _sftpOpen.remove(s)),
                      ),
                    ),
                ],
              );
            }).toList(),
          ),
        ),
        if (!_sftpOpen.contains(_active))
          TerminalKeybar(
            terminal: _active.terminal,
            config: _keybarConfig,
            onFontIncrease: () => _changeFont(1),
            onFontDecrease: () => _changeFont(-1),
            onMenu: _showSettings,
          ),
      ],
    );
  }
}
