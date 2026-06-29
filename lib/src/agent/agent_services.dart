// lib/src/agent/agent_services.dart
//
// Gestiona el ciclo de vida de los servicios del agente:
//   - llama-server (:8080)  -> servidor de inferencia LOCAL (Gemma)
//   - agent-server (:8765)  -> bucle ReAct (smolagents)
//
// La FUENTE de inferencia es configurable: el agente puede usar el llama local,
// un equipo de la LAN, o un proveedor en la nube compatible con OpenAI (Groq,
// Gemini, etc.). En modo remoto NO se arranca el llama local.
//
// La API key se guarda en almacenamiento privado de la app (no en el rootfs) y
// se inyecta al agente como variable de entorno EFÍMERA al arrancar.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../container/container_manager.dart';

/// Un fichero .gguf encontrado dentro del rootfs.
class ModelFile {
  final String prootPath;
  final String name;
  final int sizeBytes;
  ModelFile(this.prootPath, this.name, this.sizeBytes);

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }
}

/// Control del foreground service nativo (Kotlin) vía MethodChannel.
class ForegroundService {
  static const MethodChannel _ch =
      MethodChannel('linux_container/foreground');
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

  // ---- Fuente de inferencia -------------------------------------------------
  // 'local' = llama-server local; cualquier otro id = endpoint remoto OpenAI.

  String sourceId = 'groq';
  String remoteBaseUrl = '';
  String remoteModel = '';
  String remoteApiKey = '';

  bool get usingRemote => sourceId != 'local' && sourceId != 'gpu_local';

  // ---- Modelo local ---------------------------------------------------------

  String llamaModelRef = 'unsloth/gemma-4-E2B-it-GGUF:Q4_K_M';

  String? llamaLocalModelPath =
      '/root/models/models--ggml-org--gemma-4-E2B-it-GGUF/snapshots/a1dac71d3ab220618f5a7573a52acdc4baf3ae3b/gemma-4-E2B-it-Q8_0.gguf';

  // ---- Parámetros de inferencia local ---------------------------------------

  int llamaThreads = 6;
  int llamaCtx = 8192;
  String kvCacheType = 'q4_0';
  double temp = 1.0;
  double topP = 0.95;
  int topK = 64;
  int llamaPort = 8080;
  int agentPort = 8765;

  static const int _minModelBytes = 200 * 1024 * 1024;

  Pty? _llamaPty;
  Pty? _agentPty;

  final ValueNotifier<List<String>> llamaLog = ValueNotifier<List<String>>([]);
  final ValueNotifier<List<String>> agentLog = ValueNotifier<List<String>>([]);
  final ValueNotifier<bool> llamaStarting = ValueNotifier<bool>(false);
  final ValueNotifier<bool> agentStarting = ValueNotifier<bool>(false);

  bool get llamaLaunched => _llamaPty != null;
  bool get agentLaunched => _agentPty != null;
  bool get usingLocalModel =>
      llamaLocalModelPath != null && llamaLocalModelPath!.trim().isNotEmpty;

  String get currentModelLabel {
    if (usingRemote) return remoteModel.isNotEmpty ? remoteModel : sourceId;
    if (usingLocalModel) return llamaLocalModelPath!.split('/').last;
    return llamaModelRef;
  }

  // Base URL OpenAI segun la fuente activa (para el chat).
  String get effectiveBaseUrl {
    if (sourceId == 'gpu_local') return 'http://127.0.0.1:8090/v1';
    if (usingRemote) {
      return remoteBaseUrl.isNotEmpty
          ? remoteBaseUrl
          : 'http://127.0.0.1:$llamaPort/v1';
    }
    return 'http://127.0.0.1:$llamaPort/v1';
  }

  String get effectiveModel {
    if (sourceId == 'gpu_local') return 'gemma3-local';
    if (usingRemote) return remoteModel.isNotEmpty ? remoteModel : sourceId;
    return 'gemma-4-e2b';
  }

  String get effectiveApiKey {
    if (sourceId == 'gpu_local') return 'local';
    if (usingRemote) return remoteApiKey.isNotEmpty ? remoteApiKey : 'not-needed';
    return 'not-needed';
  }

  static const int _maxLogLines = 250;

  // ---- Config persistente ---------------------------------------------------

  Future<String> _configFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/model_config.json';
  }

  Future<void> loadModelConfig() async {
    try {
      final f = File(await _configFilePath());
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final local = data['localPath'] as String?;
      final ref = data['hfRef'] as String?;
      llamaLocalModelPath =
          (local != null && local.isNotEmpty) ? local : null;
      if (ref != null && ref.isNotEmpty) llamaModelRef = ref;
      llamaThreads = (data['threads'] as int?) ?? llamaThreads;
      llamaCtx = (data['ctx'] as int?) ?? llamaCtx;
      kvCacheType = (data['kv'] as String?) ?? kvCacheType;
      temp = (data['temp'] as num?)?.toDouble() ?? temp;
      topP = (data['topP'] as num?)?.toDouble() ?? topP;
      topK = (data['topK'] as int?) ?? topK;
      llamaPort = (data['llamaPort'] as int?) ?? llamaPort;
      agentPort = (data['agentPort'] as int?) ?? agentPort;
      sourceId = (data['sourceId'] as String?) ?? sourceId;
      remoteBaseUrl = (data['remoteBaseUrl'] as String?) ?? remoteBaseUrl;
      remoteModel = (data['remoteModel'] as String?) ?? remoteModel;
      remoteApiKey = (data['remoteApiKey'] as String?) ?? remoteApiKey;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final f = File(await _configFilePath());
      await f.writeAsString(jsonEncode({
        'localPath': llamaLocalModelPath ?? '',
        'hfRef': llamaModelRef,
        'threads': llamaThreads,
        'ctx': llamaCtx,
        'kv': kvCacheType,
        'temp': temp,
        'topP': topP,
        'topK': topK,
        'llamaPort': llamaPort,
        'agentPort': agentPort,
        'sourceId': sourceId,
        'remoteBaseUrl': remoteBaseUrl,
        'remoteModel': remoteModel,
        'remoteApiKey': remoteApiKey,
      }));
    } catch (_) {}
  }

  Future<void> saveSettings() => _save();

  Future<void> setLocalModel(String prootPath) async {
    llamaLocalModelPath = prootPath;
    sourceId = 'local';
    await _save();
  }

  Future<void> setHfModel(String ref) async {
    llamaModelRef = ref.trim();
    llamaLocalModelPath = null;
    sourceId = 'local';
    await _save();
  }

  Future<void> setLocalSource() async {
    sourceId = 'local';
    await _save();
  }

  Future<void> setRemoteSource({
    required String id,
    required String baseUrl,
    required String model,
    required String apiKey,
  }) async {
    sourceId = id;
    remoteBaseUrl = baseUrl.trim();
    remoteModel = model.trim();
    remoteApiKey = apiKey.trim();
    await _save();
  }

  void resetSettings() {
    llamaThreads = 6;
    llamaCtx = 8192;
    kvCacheType = 'q4_0';
    temp = 1.0;
    topP = 0.95;
    topK = 64;
    llamaPort = 8080;
    agentPort = 8765;
  }

  Future<List<ModelFile>> scanLocalModels() async {
    final rootfs = _cm.rootfsPath;
    if (rootfs == null) return [];
    final modelsDir = Directory('$rootfs/root/models');
    if (!await modelsDir.exists()) return [];
    final out = <ModelFile>[];
    final seen = <String>{};
    try {
      await for (final entity
          in modelsDir.list(recursive: true, followLinks: false)) {
        final p = entity.path;
        if (!p.toLowerCase().endsWith('.gguf')) continue;
        final name = p.split('/').last;
        if (name.toLowerCase().startsWith('mmproj')) continue;
        final prootPath = p.substring(rootfs.length);
        if (!seen.add(prootPath)) continue;
        int size = 0;
        try {
          size = await File(p).length();
        } catch (_) {}
        if (size < _minModelBytes) continue;
        out.add(ModelFile(prootPath, name, size));
      }
    } catch (_) {}
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  // ---- Comandos -------------------------------------------------------------

  String _fmt(double d) => d.toStringAsFixed(2);

  String _llamaCommand() {
    final modelArg = usingLocalModel
        ? '-m ${llamaLocalModelPath!.trim()}'
        : '-hf $llamaModelRef';
    final kvFlag =
        kvCacheType == 'f16' ? '' : ' -ctk $kvCacheType -ctv $kvCacheType';
    return 'cd /root/llama.cpp; ./build/bin/llama-server $modelArg '
            '--host 127.0.0.1 --port $llamaPort -c $llamaCtx -t $llamaThreads -fa on$kvFlag '
            '--temp ${_fmt(temp)} --top-p ${_fmt(topP)} --top-k $topK '
        r'& echo $! > /tmp/llama.pid; wait';
  }

  String _agentCommand() {
    final String base;
    final String model;
    final String key;
    if (sourceId == 'gpu_local') {
      base = 'http://127.0.0.1:8090/v1';
      model = 'gemma3-local';
      key = 'local';
    } else if (usingRemote) {
      base = remoteBaseUrl.isNotEmpty
          ? remoteBaseUrl
          : 'http://127.0.0.1:$llamaPort/v1';
      model = remoteModel.isNotEmpty ? remoteModel : sourceId;
      key = remoteApiKey.isNotEmpty ? remoteApiKey : 'not-needed';
    } else {
      base = 'http://127.0.0.1:$llamaPort/v1';
      model = 'gemma-4-e2b';
      key = 'not-needed';
    }
    final env =
        "LLM_BASE_URL='$base' LLM_MODEL='$model' LLM_API_KEY='$key' "
        "LLAMA_PORT=$llamaPort AGENT_PORT=$agentPort";
    return 'cd /root && source /root/agent-env/bin/activate && $env exec python3 /root/agent_server.py';
  }

  // ---- Arranque / parada ----------------------------------------------------

  void startLlama() {
    if (_llamaPty != null) return;
    if (usingRemote) {
      _push(llamaLog, '[lc] Fuente remota activa: no se usa llama local.');
      return;
    }
    if (!_cm.isReady) {
      _push(llamaLog, '[error] El contenedor Debian aún no está listo.');
      return;
    }
    _push(llamaLog, '[lc] Arrancando llama-server… ($currentModelLabel)');
    llamaStarting.value = true;
    final pty = _cm.startProcess(_llamaCommand());
    _llamaPty = pty;
    _attach(pty, llamaLog, () {
      _llamaPty = null;
      llamaStarting.value = false;
      _push(llamaLog, '[lc] llama-server finalizó.');
      _syncForeground();
    });
    _syncForeground();
  }

  void stopLlama() {
    _push(llamaLog, '[lc] Deteniendo llama-server…');
    _killService(_llamaPty, '/tmp/llama.pid', 'build/bin/llama-server');
    _llamaPty = null;
    llamaStarting.value = false;
    _syncForeground();
  }

  void startAgent() {
    if (_agentPty != null) return;
    if (!_cm.isReady) {
      _push(agentLog, '[error] El contenedor Debian aún no está listo.');
      return;
    }
    final src = usingRemote ? 'remoto: $remoteBaseUrl ($remoteModel)' : 'local';
    _push(agentLog, '[XTR Agent Server v1.1]');
    _push(agentLog, '[fuente: $src | puerto: $agentPort]');
    _push(agentLog, '[Arrancando...]');
    agentStarting.value = true;
    final pty = _cm.startProcess(_agentCommand());
    _agentPty = pty;
    _attach(pty, agentLog, () {
      _agentPty = null;
      agentStarting.value = false;
      _push(agentLog, '[lc] agent-server finalizó.');
      _syncForeground();
    });
    _syncForeground();
  }

  void stopAgent() {
    _push(agentLog, '[lc] Deteniendo agent-server…');
    _killService(_agentPty, '/tmp/agent.pid', 'agent_server.py');
    _agentPty = null;
    agentStarting.value = false;
    _syncForeground();
  }

  // ---- Internos -------------------------------------------------------------

  void _syncForeground() {
    if (llamaLaunched || agentLaunched) {
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
