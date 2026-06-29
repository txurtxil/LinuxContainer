// lib/src/agent/agent_chat.dart
//
// Estado del chat del agente, SEPARADO de la UI para que:
//   - sobreviva al navegar entre Agente y Terminal,
//   - el run siga vivo aunque el panel se cierre (agente autónomo),
//   - se pueda autoguardar y guardar/cargar conversaciones con nombre.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const String kAgentHost = '127.0.0.1';

/// Un bloque de la conversación (serializable a JSON).
class ChatBlock {
  final String kind; // user | thought | tool | observation | final | error
  final String text;
  final String? toolName;
  final String? toolArgs;
  final int? step;

  ChatBlock(this.kind, this.text, {this.toolName, this.toolArgs, this.step});

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'toolName': toolName,
        'toolArgs': toolArgs,
        'step': step,
      };

  factory ChatBlock.fromJson(Map<String, dynamic> j) => ChatBlock(
        (j['kind'] as String?) ?? 'final',
        (j['text'] as String?) ?? '',
        toolName: j['toolName'] as String?,
        toolArgs: j['toolArgs'] as String?,
        step: j['step'] as int?,
      );
}

/// Metadatos de una conversación guardada.
class SavedChat {
  final String path;
  final String name;
  final String savedAt;
  SavedChat(this.path, this.name, this.savedAt);

  String get dateLabel {
    try {
      final d = DateTime.parse(savedAt).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
    } catch (_) {
      return '';
    }
  }
}

class AgentApi {
  static Future<bool> checkHealth(int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req =
          await client.getUrl(Uri.parse('http://$kAgentHost:$port/health'));
      final resp = await req.close();
      final ok = resp.statusCode == 200;
      await resp.drain<void>();
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Stream<Map<String, dynamic>> run(
    String prompt,
    int agentPort, {
    String baseUrl = '',
    String model = '',
    String apiKey = '',
  }) async* {
    final client = HttpClient();
    try {
      final req =
          await client.postUrl(Uri.parse('http://$kAgentHost:$agentPort/run'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({
        'task': prompt,
        if (baseUrl.isNotEmpty) 'llm_base_url': baseUrl,
        if (model.isNotEmpty) 'llm_model': model,
        if (apiKey.isNotEmpty) 'llm_api_key': apiKey,
      })));
      final resp = await req.close();
      await for (final line in resp
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(line.indexOf(':') + 1).trim();
        if (payload.isEmpty) continue;
        Map<String, dynamic>? map;
        try {
          map = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          map = null;
        }
        if (map != null) yield map;
      }
    } catch (e) {
      yield {'type': 'error', 'error': e.toString()};
    } finally {
      client.close(force: true);
    }
  }
}

/// Controlador singleton: dueño del estado del chat y del run en curso.
class AgentController {
  static final AgentController _i = AgentController._();
  factory AgentController() => _i;
  AgentController._();

  final ValueNotifier<List<ChatBlock>> blocks =
      ValueNotifier<List<ChatBlock>>([]);
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _loaded = false;

  // ---- Mutación -------------------------------------------------------------

  void _append(ChatBlock b) {
    blocks.value = [...blocks.value, b];
  }

  void addError(String text) {
    _append(ChatBlock('error', text));
    _saveCurrent();
  }

  String _fmtArgs(dynamic args) {
    if (args is Map) {
      return args.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    }
    return args.toString();
  }

  void _ingest(Map<String, dynamic> e) {
    final type = e['type'] as String?;
    if (type == 'step') {
      final step = e['step'] as int?;
      final thought = (e['thought'] as String?)?.trim();
      if (thought != null && thought.isNotEmpty) {
        _append(ChatBlock('thought', thought, step: step));
      }
      final calls = e['tool_calls'] as List<dynamic>?;
      if (calls != null) {
        for (final c in calls) {
          final m = c as Map<String, dynamic>;
          final name = m['name']?.toString() ?? 'tool';
          final args = m['arguments'];
          _append(ChatBlock('tool', '',
              toolName: name,
              toolArgs: args == null ? null : _fmtArgs(args),
              step: step));
        }
      }
      final obs = (e['observation'] as String?)?.trim();
      if (obs != null && obs.isNotEmpty) {
        _append(ChatBlock('observation', obs, step: step));
      }
      final err = (e['error'] as String?)?.trim();
      if (err != null && err.isNotEmpty) {
        _append(ChatBlock('error', err, step: step));
      }
    } else if (type == 'final') {
      _append(ChatBlock('final', e['answer']?.toString() ?? ''));
    } else if (type == 'error') {
      _append(ChatBlock('error', e['error']?.toString() ?? 'error'));
    }
  }

  void send(
    String prompt,
    int agentPort, {
    String baseUrl = '',
    String model = '',
    String apiKey = '',
  }) {
    if (running.value) return;
    _append(ChatBlock('user', prompt));
    running.value = true;
    _saveCurrent();
    _sub = AgentApi.run(prompt, agentPort, baseUrl: baseUrl, model: model, apiKey: apiKey).listen(
      _ingest,
      onDone: () {
        running.value = false;
        _saveCurrent();
      },
      onError: (Object err) {
        _append(ChatBlock('error', err.toString()));
        running.value = false;
        _saveCurrent();
      },
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    running.value = false;
  }

  void clear() {
    stop();
    blocks.value = [];
    _saveCurrent();
  }

  // ---- Persistencia ---------------------------------------------------------

  Future<Directory> _chatsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/chats');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _saveCurrent() async {
    try {
      final d = await _chatsDir();
      final f = File('${d.path}/current.json');
      await f.writeAsString(
          jsonEncode(blocks.value.map((b) => b.toJson()).toList()));
    } catch (_) {}
  }

  /// Carga la conversación autoguardada (una sola vez al arrancar).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final d = await _chatsDir();
      final f = File('${d.path}/current.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List<dynamic>;
        blocks.value = list
            .map((e) => ChatBlock.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
  }

  Future<void> saveAs(String name) async {
    try {
      final d = await _chatsDir();
      final ts = DateTime.now();
      final id = ts.millisecondsSinceEpoch.toString();
      final f = File('${d.path}/chat-$id.json');
      await f.writeAsString(jsonEncode({
        'name': name.trim().isEmpty ? 'Sin nombre' : name.trim(),
        'savedAt': ts.toIso8601String(),
        'blocks': blocks.value.map((b) => b.toJson()).toList(),
      }));
    } catch (_) {}
  }

  Future<List<SavedChat>> listSaved() async {
    final out = <SavedChat>[];
    try {
      final d = await _chatsDir();
      await for (final e in d.list()) {
        if (e is File &&
            e.path.contains('/chat-') &&
            e.path.endsWith('.json')) {
          try {
            final m =
                jsonDecode(await e.readAsString()) as Map<String, dynamic>;
            out.add(SavedChat(
              e.path,
              (m['name'] as String?) ?? 'Sin nombre',
              (m['savedAt'] as String?) ?? '',
            ));
          } catch (_) {}
        }
      }
    } catch (_) {}
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  Future<void> loadSaved(String path) async {
    try {
      final m =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final list = (m['blocks'] as List<dynamic>);
      blocks.value = list
          .map((e) => ChatBlock.fromJson(e as Map<String, dynamic>))
          .toList();
      await _saveCurrent();
    } catch (_) {}
  }

  Future<void> deleteSaved(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
