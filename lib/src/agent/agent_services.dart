// lib/src/agent/agent_services.dart — v8.0
// Arregla: httpx no instalado → pip install auto + fallback a stdlib.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../container/container_manager.dart';

class ForegroundService {
  static const MethodChannel _ch = MethodChannel('linux_container/foreground');
  static bool _active = false;

  static Future<void> start() async {
    if (_active) return;
    _active = true;
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}

class AgentServices {
  static final AgentServices _i = AgentServices._();
  factory AgentServices() => _i;
  AgentServices._();

  final ContainerManager _cm = ContainerManager();
  String? get rootfsPathForView => _cm.rootfsPath;

  String sourceId = 'gpu_local';
  String remoteBaseUrl = '';
  String remoteModel = '';
  String remoteApiKey = '';

  double temp = 1.0;
  double topP = 0.95;
  int topK = 64;
  int agentPort = 8765;

  static const MethodChannel _mpCh = MethodChannel('xtr/mediapipe');
  static const EventChannel _mpStream = EventChannel('xtr/mediapipe/stream');

  bool mpLoaded = false;
  bool mpLoading = false;
  bool mpServerRunning = false;
  bool mpServerBusy = false;
  bool mpGenerating = false;
  String mpStatus = 'Sin cargar.';
  String mpOutput = '';
  String mpStats = '';
  String? mpSelectedPath;
  bool mpUseGpu = true;
  List<FileSystemEntity> mpModels = [];
  String? mpModelsDir;

  StreamSubscription? _mpSub;

  Pty? _agentPty;
  Pty? _cronPty;

  final ValueNotifier<List<String>> agentLog = ValueNotifier<List<String>>([]);
  final ValueNotifier<List<String>> cronLog = ValueNotifier<List<String>>([]);
  final ValueNotifier<bool> agentStarting = ValueNotifier<bool>(false);
  final ValueNotifier<bool> cronStarting = ValueNotifier<bool>(false);
  final ValueNotifier<bool> agentFailed = ValueNotifier<bool>(false);

  bool get agentLaunched => _agentPty != null;
  bool get cronLaunched => _cronPty != null;

  String get currentModelLabel {
    if (sourceId == 'gpu_local') return 'GPU Local';
    return remoteModel.isNotEmpty ? remoteModel : 'Personalizado';
  }

  String get effectiveBaseUrl {
    if (sourceId == 'gpu_local') return 'http://127.0.0.1:8090/v1';
    return remoteBaseUrl.isNotEmpty ? remoteBaseUrl : '';
  }

  String get effectiveModel {
    if (sourceId == 'gpu_local') return 'gemma3-local';
    return remoteModel.isNotEmpty ? remoteModel : 'custom';
  }

  String get effectiveApiKey {
    if (sourceId == 'gpu_local') return 'local';
    return remoteApiKey.isNotEmpty ? remoteApiKey : 'not-needed';
  }

  static const int _maxLogLines = 250;

  Future<String> _configFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/model_config.json';
  }

  Future<void> loadModelConfig() async {
    try {
      final f = File(await _configFilePath());
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      sourceId = (data['sourceId'] as String?) ?? sourceId;
      remoteBaseUrl = (data['remoteBaseUrl'] as String?) ?? remoteBaseUrl;
      remoteModel = (data['remoteModel'] as String?) ?? remoteModel;
      remoteApiKey = (data['remoteApiKey'] as String?) ?? remoteApiKey;
      temp = (data['temp'] as num?)?.toDouble() ?? temp;
      topP = (data['topP'] as num?)?.toDouble() ?? topP;
      topK = (data['topK'] as int?) ?? topK;
      agentPort = (data['agentPort'] as int?) ?? agentPort;
      mpUseGpu = (data['mpUseGpu'] as bool?) ?? mpUseGpu;
      mpSelectedPath = data['mpSelectedPath'] as String?;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final f = File(await _configFilePath());
      await f.writeAsString(jsonEncode({
        'sourceId': sourceId,
        'remoteBaseUrl': remoteBaseUrl,
        'remoteModel': remoteModel,
        'remoteApiKey': remoteApiKey,
        'temp': temp,
        'topP': topP,
        'topK': topK,
        'agentPort': agentPort,
        'mpUseGpu': mpUseGpu,
        'mpSelectedPath': mpSelectedPath,
      }));
    } catch (_) {}
  }

  Future<void> saveSettings() => _save();

  Future<void> setSource({
    required String id,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    sourceId = id;
    if (baseUrl != null) remoteBaseUrl = baseUrl.trim();
    if (model != null) remoteModel = model.trim();
    if (apiKey != null) remoteApiKey = apiKey.trim();
    await _save();
  }

  void resetSettings() {
    temp = 1.0;
    topP = 0.95;
    topK = 64;
    agentPort = 8765;
    mpUseGpu = true;
  }

  Future<void> scanMpModels() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return;
      final dir = Directory('${ext.path}/models');
      mpModelsDir = dir.path;
      if (!await dir.exists()) await dir.create(recursive: true);
      final found = <FileSystemEntity>[];
      await for (final e in dir.list()) {
        final lp = e.path.toLowerCase();
        if (e is File && (lp.endsWith('.task') || lp.endsWith('.litertlm'))) {
          found.add(e);
        }
      }
      found.sort((a, b) => a.path.compareTo(b.path));
      mpModels = found;
      if (mpSelectedPath == null && found.isNotEmpty) {
        mpSelectedPath = found.first.path;
      }
    } catch (e) {
      mpStatus = 'Error escaneando: $e';
    }
  }

  Future<String?> importMpModel() async {
    try {
      final path = await _mpCh.invokeMethod<String>('importModel');
      if (path != null) {
        await scanMpModels();
        mpSelectedPath = path;
        mpStatus = 'Importado: ${path.split('/').last}';
      }
      return path;
    } on PlatformException catch (e) {
      mpStatus = 'Error importando: ${e.message}';
      return null;
    }
  }

  Future<void> deleteMpModel(String path) async {
    try {
      await File(path).delete();
      if (mpSelectedPath == path) {
        mpSelectedPath = null;
        mpLoaded = false;
        mpStatus = 'Modelo borrado.';
      }
      await scanMpModels();
    } catch (e) {
      mpStatus = 'Error borrando: $e';
    }
  }

  Future<void> loadMpModel() async {
    final path = mpSelectedPath;
    if (path == null) {
      mpStatus = 'Selecciona un modelo primero.';
      return;
    }
    mpLoading = true;
    mpLoaded = false;
    mpStatus = 'Cargando en ${mpUseGpu ? 'GPU' : 'CPU'}...';
    final t0 = DateTime.now();
    try {
      await _mpCh.invokeMethod('load', {'path': path, 'gpu': mpUseGpu});
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      mpLoading = false;
      mpLoaded = true;
      mpStatus = 'Cargado en ${secs.toStringAsFixed(1)}s (${mpUseGpu ? 'GPU' : 'CPU'}).';
    } on PlatformException catch (e) {
      mpLoading = false;
      mpStatus = 'Fallo al cargar: ${e.message}';
    }
  }

  Future<void> unloadMpModel() async {
    try {
      await _mpCh.invokeMethod('unload');
    } catch (_) {}
    mpLoaded = false;
    mpStatus = 'Modelo liberado.';
    mpOutput = '';
    mpStats = '';
  }

  void listenMpEvents(Function(Map) onEvent) {
    _mpSub?.cancel();
    _mpSub = _mpStream.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) onEvent(event);
      },
      onError: (_) {
        mpGenerating = false;
        mpStatus = 'Error de stream MediaPipe';
      },
    );
  }

  void cancelMpEvents() {
    _mpSub?.cancel();
    _mpSub = null;
  }

  Future<void> generateMpTest(String prompt) async {
    if (!mpLoaded || mpGenerating) return;
    mpGenerating = true;
    mpOutput = '';
    mpStats = '';
    try {
      await _mpCh.invokeMethod('generate', {'prompt': prompt});
    } on PlatformException catch (e) {
      mpGenerating = false;
      mpStatus = 'Fallo al generar: ${e.message}';
    }
  }

  void handleMpEvent(Map event) {
    if (event['stats'] == true) {
      final tps = (event['tps'] as num?)?.toDouble() ?? 0;
      final toks = (event['tokens'] as num?)?.toInt() ?? 0;
      final ttft = (event['ttft'] as num?)?.toDouble() ?? 0;
      mpGenerating = false;
      mpStats = '${tps.toStringAsFixed(1)} tok/s · $toks tokens · TTFT ${ttft.toStringAsFixed(2)}s';
      return;
    }
    final partial = event['partial'] as String? ?? '';
    final done = event['done'] == true;
    mpOutput += partial;
    if (done) mpGenerating = false;
  }

  Future<void> startMpServer() async {
    if (!mpLoaded) {
      mpStatus = 'Carga un modelo primero.';
      return;
    }
    mpServerBusy = true;
    mpStatus = 'Iniciando servidor...';
    try {
      await _mpCh.invokeMethod('serverStart',
          {'port': 8090, 'path': mpSelectedPath, 'gpu': mpUseGpu});
      mpServerRunning = true;
      mpServerBusy = false;
      mpStatus = 'Servidor activo: http://127.0.0.1:8090/v1';
    } on PlatformException catch (e) {
      mpServerBusy = false;
      mpStatus = 'Error servidor: ${e.message}';
    }
  }

  Future<void> stopMpServer() async {
    try {
      await _mpCh.invokeMethod('serverStop');
    } catch (_) {}
    mpServerRunning = false;
    mpStatus = 'Servidor detenido.';
  }

  Future<void> syncMpStatus() async {
    try {
      final st = await _mpCh.invokeMapMethod<String, dynamic>('serverStatus');
      if (st == null) return;
      mpLoaded = st['modelLoaded'] as bool? ?? false;
      mpServerRunning = st['running'] as bool? ?? false;
      final path = st['modelPath'] as String? ?? '';
      if (path.isNotEmpty && mpLoaded) {
        mpSelectedPath = path;
        mpStatus = 'Modelo cargado (sesion activa).';
      }
      if (mpServerRunning) {
        mpStatus = 'Servidor activo: http://127.0.0.1:8090/v1';
      }
    } catch (_) {}
  }

  Future<bool> ensureAgentScript() async {
    final rootfs = _cm.rootfsPath;
    if (rootfs == null) {
      _push(agentLog, '[error] rootfs no disponible.');
      return false;
    }
    final target = File('$rootfs/root/agent_server.py');
    if (await target.exists()) {
      _push(agentLog, '[ok] agent_server.py ya existe en rootfs.');
      return true;
    }
    _push(agentLog, '[..] Copiando agent_server.py desde assets...');
    try {
      final bytes = await rootBundle.load('assets/agent_server.py');
      final data = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      await target.writeAsBytes(data);
      _push(agentLog, '[ok] agent_server.py copiado (${data.length} bytes).');
      return true;
    } catch (e) {
      _push(agentLog, '[error] No se pudo copiar agent_server.py: $e');
      _push(agentLog, '[hint] Asegurate de que assets/agent_server.py este en pubspec.yaml');
      return false;
    }
  }

  // ---- ARREGLO CRITICO v8: python3 + pip install auto ---------------------
  String _agentCommand() {
    final base = effectiveBaseUrl;
    final model = effectiveModel;
    final key = effectiveApiKey;
    // v8: busca python3, instala pip si falta, instala httpx si el script lo necesita,
    //     pero el fallback usa stdlib asi que nunca falla por deps.
    return r"""cd /root && \
if [ ! -f /root/agent_server.py ]; then echo '[ERROR] No existe /root/agent_server.py'; exit 1; fi; \
PYTHON=''; for P in /root/agent-env/bin/python3 /usr/bin/python3 /usr/local/bin/python3 /bin/python3; do \
  if [ -x "$P" ]; then PYTHON="$P"; break; fi; done; \
if [ -z "$PYTHON" ]; then \
  echo '[XTR] python3 no encontrado. Intentando instalar...'; \
  if command -v apt-get >/dev/null 2>&1; then \
    apt-get update -qq && apt-get install -y -qq python3 python3-venv python3-pip 2>/dev/null; \
  elif command -v apk >/dev/null 2>&1; then \
    apk add --no-cache python3 py3-pip 2>/dev/null; \
  elif command -v pacman >/dev/null 2>&1; then \
    pacman -Sy --noconfirm python python-pip 2>/dev/null; \
  fi; \
  for P in /usr/bin/python3 /usr/local/bin/python3 /bin/python3; do \
    if [ -x "$P" ]; then PYTHON="$P"; break; fi; done; \
fi; \
if [ -z "$PYTHON" ]; then \
  echo '[FATAL] No se encontro ni se pudo instalar python3.'; \
  echo '[hint] Entra al contenedor y ejecuta: apt-get update && apt-get install -y python3'; \
  exit 1; fi; \
# v8: asegurar pip e instalar deps si el script las necesita \
if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then \
  echo '[XTR] pip no encontrado. Instalando...'; \
  "$PYTHON" -m ensurepip --upgrade 2>/dev/null || \
    (apt-get install -y -qq python3-pip 2>/dev/null); \
fi; \
# Instalar deps comunes silenciosamente (no falla si ya estan) \
echo '[XTR] Verificando dependencias...'; \
"$PYTHON" -m pip install -q --upgrade pip 2>/dev/null || true; \
"$PYTHON" -m pip install -q httpx openai 2>/dev/null || echo '[warn] No se pudieron instalar deps opcionales (httpx/openai). El fallback usa stdlib.'; \
if [ -f /root/agent-env/bin/activate ]; then . /root/agent-env/bin/activate; fi; \
export LLM_BASE_URL='""" + base + r"""' LLM_MODEL='""" + model + r"""' LLM_API_KEY='""" + key + r"""' AGENT_PORT=""" + agentPort.toString() + r"""; \
echo "[XTR] Usando python: $PYTHON"; \
echo "[XTR] LLM_BASE_URL=$LLM_BASE_URL"; \
echo "[XTR] Modelo=$LLM_MODEL"; \
echo "[XTR] Puerto=$AGENT_PORT"; \
exec "$PYTHON" /root/agent_server.py""";
  }

  Future<void> startAgent() async {
    if (_agentPty != null) return;
    if (!_cm.isReady) {
      _push(agentLog, '[error] El contenedor Debian aun no esta listo.');
      _push(agentLog, '[hint] Espera a que el contenedor termine de inicializarse.');
      agentFailed.value = true;
      return;
    }
    final ok = await ensureAgentScript();
    if (!ok) {
      agentFailed.value = true;
      return;
    }
    final src = sourceId == 'gpu_local' ? 'GPU Local (MediaPipe)' : 'Remoto: $remoteBaseUrl';
    agentLog.value = [];
    _push(agentLog, '[XTR Agent Server v8.0]');
    _push(agentLog, '[fuente: $src | puerto: $agentPort]');
    _push(agentLog, '[Arrancando...]');
    agentStarting.value = true;
    agentFailed.value = false;
    final pty = _cm.startProcess(_agentCommand());
    _agentPty = pty;
    _attach(pty, agentLog, () {
      _agentPty = null;
      agentStarting.value = false;
      _push(agentLog, '[lc] agent-server finalizo.');
      _syncForeground();
    });
    _syncForeground();
  }

  void stopAgent() {
    _push(agentLog, '[lc] Deteniendo agent-server...');
    _killService(_agentPty, '/tmp/agent.pid', 'agent_server.py');
    _agentPty = null;
    agentStarting.value = false;
    agentFailed.value = false;
    _syncForeground();
  }

  void startCron() {
    if (_cronPty != null) return;
    if (!_cm.isReady) {
      _push(cronLog, '[error] El contenedor Debian aun no esta listo.');
      return;
    }
    _push(cronLog, '[XTR Cron]');
    _push(cronLog, '[Arrancando scheduler...]');
    cronStarting.value = true;
    final pty = _cm.startProcess('/usr/sbin/cron -f -L 15');
    _cronPty = pty;
    _attach(pty, cronLog, () {
      _cronPty = null;
      cronStarting.value = false;
      _push(cronLog, '[lc] cron finalizo.');
      _syncForeground();
    });
    _syncForeground();
  }

  void stopCron() {
    _push(cronLog, '[lc] Deteniendo cron...');
    _killService(_cronPty, '/tmp/cron.pid', '/usr/sbin/cron');
    _cronPty = null;
    cronStarting.value = false;
    _syncForeground();
  }

  void _syncForeground() {
    if (agentLaunched || cronLaunched) {
      ForegroundService.start();
    } else {
      ForegroundService.stop();
    }
  }

  void _attach(Pty pty, ValueNotifier<List<String>> log, VoidCallback onExit) {
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((data) {
      for (final line in const LineSplitter().convert(data)) {
        _push(log, line);
      }
    }, onError: (_) {}, cancelOnError: false);
    pty.exitCode.then((_) => onExit());
  }

  void _killService(Pty? held, String pidFile, String pattern) {
    try {
      held?.kill();
    } catch (_) {}
    if (!_cm.isReady) return;
    final cleanup = r'P=$(cat ' +
        pidFile +
        r' 2>/dev/null); if [ -n "$P" ]; then kill $P 2>/dev/null; sleep 0.4; kill -9 $P 2>/dev/null; fi; pkill -9 -f "' +
        pattern +
        r'" 2>/dev/null; rm -f ' +
        pidFile +
        r'; exit 0';
    try {
      final p = _cm.startProcess(cleanup);
      Future.delayed(const Duration(seconds: 3), () {
        try {
          p.kill();
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _push(ValueNotifier<List<String>> log, String line) {
    final updated = List<String>.from(log.value)..add(line);
    while (updated.length > _maxLogLines) {
      updated.removeAt(0);
    }
    log.value = updated;
  }
}
