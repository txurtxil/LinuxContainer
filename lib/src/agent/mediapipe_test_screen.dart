// lib/src/agent/mediapipe_test_screen.dart
//
// FASE 1 (prueba de vida): carga un modelo .task con MediaPipe y genera texto
// en GPU, mostrando TTFT y tokens/segundo. Sin agente, sin servidor.
// Su único objetivo es confirmar que la GPU del dispositivo funciona y es rápida.

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _bg = Color(0xFF1C1C1E);
const _card = Color(0xFF2C2C2E);
const _border = Color(0xFF3A3A3C);
const _textHi = Color(0xFFEAEAEC);
const _textLo = Color(0xFF9A9AA0);
const _accent = Color(0xFF5E9BD6);
const _ok = Color(0xFF34C759);
const _err = Color(0xFFFF453A);

class MediaPipeTestScreen extends StatefulWidget {
  const MediaPipeTestScreen({super.key});

  @override
  State<MediaPipeTestScreen> createState() => _MediaPipeTestScreenState();
}

class _MediaPipeTestScreenState extends State<MediaPipeTestScreen> {
  static const _method = MethodChannel('xtr/mediapipe');
  static const _stream = EventChannel('xtr/mediapipe/stream');

  StreamSubscription? _sub;
  final _prompt = TextEditingController(
      text: 'Explica en dos frases qué es un agujero negro.');

  List<FileSystemEntity> _models = [];
  String? _selected;
  bool _useGpu = true;

  bool _loading = false;
  bool _loaded = false;
  bool _generating = false;
  String _status = 'Sin cargar.';
  String _output = '';
  String _stats = '';
  String? _modelsDir;

  bool _serverRunning = false;
  bool _serverBusy = false;
  String _serverMsg = '';

  @override
  void initState() {
    super.initState();
    _scanModels();
    _syncStatus();
    _sub = _stream.receiveBroadcastStream().listen(_onEvent, onError: (e) {
      setState(() {
        _generating = false;
        _status = 'Error de stream: $e';
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _syncStatus() async {
    try {
      final st = await _method.invokeMapMethod<String, dynamic>('serverStatus');
      if (st == null) return;
      final loaded = st['modelLoaded'] as bool? ?? false;
      final running = st['running'] as bool? ?? false;
      final path = st['modelPath'] as String? ?? '';
      final port = st['port'] as int? ?? 8090;
      setState(() {
        _loaded = loaded;
        _serverRunning = running;
        if (path.isNotEmpty && loaded) {
          _selected = path;
          _status = 'Modelo cargado (sesion activa).';
        }
        if (running) {
          _serverMsg = 'Activo: http://127.0.0.1:$port/v1';
        }
      });
    } catch (_) {}
  }

  Future<void> _scanModels() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return;
      final dir = Directory('${ext.path}/models');
      _modelsDir = dir.path;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final found = <FileSystemEntity>[];
      await for (final e in dir.list()) {
        final lp = e.path.toLowerCase();
        if (e is File && (lp.endsWith('.task') || lp.endsWith('.litertlm'))) {
          found.add(e);
        }
      }
      found.sort((a, b) => a.path.compareTo(b.path));
      setState(() {
        _models = found;
        _selected = found.isNotEmpty ? found.first.path : null;
      });
    } catch (e) {
      setState(() => _status = 'No pude escanear modelos: $e');
    }
  }

  Future<void> _importModel() async {
    setState(() => _status =
        'Abriendo selector… elige el .task (la copia puede tardar 1-2 min).');
    try {
      final path = await _method.invokeMethod<String>('importModel');
      if (path == null) {
        setState(() => _status = 'Importación cancelada.');
        return;
      }
      final lpath = path.toLowerCase();
      if (!lpath.endsWith('.task') && !lpath.endsWith('.litertlm')) {
        setState(() => _status = 'Aviso: el fichero no acaba en .task ni .litertlm.');
      }
      await _scanModels();
      setState(() {
        _selected = path;
        _status = 'Importado: ${path.split('/').last}';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error importando: ${e.message}');
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    if (event['stats'] == true) {
      final tps = (event['tps'] as num?)?.toDouble() ?? 0;
      final toks = (event['tokens'] as num?)?.toInt() ?? 0;
      final ttft = (event['ttft'] as num?)?.toDouble() ?? 0;
      setState(() {
        _generating = false;
        _stats =
            '⚡ ${tps.toStringAsFixed(1)} tok/s · $toks tokens · TTFT ${ttft.toStringAsFixed(2)}s';
      });
      return;
    }
    final partial = event['partial'] as String? ?? '';
    final done = event['done'] == true;
    setState(() {
      _output += partial;
      if (done) _generating = false;
    });
  }

  Future<void> _load() async {
    final path = _selected;
    if (path == null) {
      setState(() => _status = 'No hay ningún modelo (.task/.litertlm) seleccionado.');
      return;
    }
    setState(() {
      _loading = true;
      _loaded = false;
      _status = 'Cargando en ${_useGpu ? "GPU" : "CPU"}…';
    });
    final t0 = DateTime.now();
    try {
      await _method.invokeMethod('load', {'path': path, 'gpu': _useGpu});
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      setState(() {
        _loading = false;
        _loaded = true;
        _status = 'Modelo cargado en ${secs.toStringAsFixed(1)}s '
            '(${_useGpu ? "GPU" : "CPU"}).';
      });
    } on PlatformException catch (e) {
      setState(() {
        _loading = false;
        _status = 'Fallo al cargar: ${e.message}';
      });
    }
  }

  Future<void> _generate() async {
    if (!_loaded || _generating) return;
    setState(() {
      _generating = true;
      _output = '';
      _stats = '';
    });
    try {
      await _method.invokeMethod('generate', {'prompt': _prompt.text});
    } on PlatformException catch (e) {
      setState(() {
        _generating = false;
        _status = 'Fallo al generar: ${e.message}';
      });
    }
  }

  Future<void> _unload() async {
    try {
      await _method.invokeMethod('unload');
    } catch (_) {}
    setState(() {
      _loaded = false;
      _status = 'Modelo liberado.';
      _output = '';
      _stats = '';
    });
  }

  Future<void> _deleteModel(String path) async {
    final name = path.split('/').last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text('Borrar modelo',
            style: TextStyle(color: Color(0xFFEAEAEC))),
        content: Text('¿Eliminar $name?',
            style: const TextStyle(color: Color(0xFF9A9AA0))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar',
                  style: TextStyle(color: Color(0xFF9A9AA0)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar',
                  style: TextStyle(color: Color(0xFFFF453A)))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(path).delete();
      if (_selected == path) {
        setState(() {
          _selected = null;
          _loaded = false;
          _status = 'Modelo borrado.';
        });
      }
      await _scanModels();
    } catch (e) {
      setState(() => _status = 'Error borrando: $e');
    }
  }

  Future<void> _startServer() async {
    if (!_loaded) {
      setState(() => _serverMsg = 'Carga un modelo primero.');
      return;
    }
    setState(() {
      _serverBusy = true;
      _serverMsg = 'Iniciando servidor…';
    });
    try {
      await _method.invokeMethod('serverStart',
          {'port': 8090, 'path': _selected, 'gpu': _useGpu});
      setState(() {
        _serverRunning = true;
        _serverBusy = false;
        _serverMsg = 'Activo: http://127.0.0.1:8090/v1';
      });
    } on PlatformException catch (e) {
      setState(() {
        _serverBusy = false;
        _serverMsg = 'Error: ${e.message}';
      });
    }
  }

  Future<void> _stopServer() async {
    try {
      await _method.invokeMethod('serverStop');
    } catch (_) {}
    setState(() {
      _serverRunning = false;
      _serverMsg = 'Servidor detenido.';
    });
  }

  Future<void> _testServer() async {
    setState(() {
      _serverBusy = true;
      _serverMsg = 'Probando /v1/chat/completions…';
    });
    final client = HttpClient();
    final t0 = DateTime.now();
    try {
      final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:8090/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': 'Di "hola" y nada mas.'}
        ],
        'stream': false,
      })));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      String content;
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        content = (j['choices'][0]['message']['content'] as String?) ?? body;
      } catch (_) {
        content = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      }
      setState(() {
        _serverBusy = false;
        _serverMsg = '✅ ${secs.toStringAsFixed(1)}s · "$content"';
      });
    } catch (e) {
      setState(() {
        _serverBusy = false;
        _serverMsg = 'Error probando: $e';
      });
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _textHi,
        title: const Text('Prueba GPU · MediaPipe',
            style: TextStyle(fontSize: 16)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _label('Modelo (.task / .litertlm)'),
            const SizedBox(height: 8),
            if (_models.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: _box(),
                child: Text(
                  'No hay modelos (.task/.litertlm) en:\n${_modelsDir ?? "(carpeta de modelos)"}\n\n'
                  'Copia ahí un modelo (p. ej. gemma3-1b-it-int4.task) y recarga.',
                  style: const TextStyle(
                      color: _textLo, fontSize: 12.5, height: 1.5),
                ),
              )
            else
              Container(
                decoration: _box(),
                child: Column(
                  children: _models.map((m) {
                    final p = m.path;
                    final name = p.split('/').last;
                    final selected = p == _selected;
                    return InkWell(
                      onTap: _loaded ? null : () => setState(() => _selected = p),
                      child: Padding(
                        padding: const EdgeInsets.only(
                            left: 12, right: 4, top: 8, bottom: 8),
                        child: Row(
                          children: [
                            Icon(
                              selected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: selected ? _accent : _textLo,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(name,
                                  style: TextStyle(
                                      color: selected ? _textHi : _textLo,
                                      fontSize: 13),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: Color(0xFFFF453A)),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 36, minHeight: 36),
                              tooltip: 'Borrar',
                              onPressed: () => _deleteModel(p),
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
                  onPressed: _importModel,
                  icon: const Icon(Icons.file_download_outlined,
                      size: 16, color: _accent),
                  label: const Text('Importar modelo',
                      style: TextStyle(color: _accent, fontSize: 12.5)),
                ),
                TextButton.icon(
                  onPressed: _scanModels,
                  icon: const Icon(Icons.refresh, size: 16, color: _textLo),
                  label: const Text('Recargar',
                      style: TextStyle(color: _textLo, fontSize: 12.5)),
                ),
                const Spacer(),
                const Text('Backend:',
                    style: TextStyle(color: _textLo, fontSize: 12.5)),
                const SizedBox(width: 8),
                ToggleButtons(
                  isSelected: [_useGpu, !_useGpu],
                  onPressed: _loaded
                      ? null
                      : (i) => setState(() => _useGpu = i == 0),
                  borderRadius: BorderRadius.circular(8),
                  borderColor: _border,
                  selectedBorderColor: _accent,
                  fillColor: _accent,
                  color: _textLo,
                  selectedColor: Colors.white,
                  constraints:
                      const BoxConstraints(minHeight: 32, minWidth: 52),
                  children: const [Text('GPU'), Text('CPU')],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _loaded ? _card : _accent,
                      foregroundColor: _loaded ? _textLo : Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(_loaded ? Icons.check : Icons.bolt, size: 18),
                    label: Text(_loaded ? 'Cargado' : 'Cargar modelo'),
                    onPressed: (_loading || _loaded) ? null : _load,
                  ),
                ),
                if (_loaded) ...[
                  const SizedBox(width: 10),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _err,
                      side: const BorderSide(color: _border),
                      padding: const EdgeInsets.symmetric(
                          vertical: 13, horizontal: 16),
                    ),
                    onPressed: _unload,
                    child: const Text('Liberar'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(),
              child: Row(
                children: [
                  Icon(
                    _loaded ? Icons.check_circle : Icons.info_outline,
                    size: 16,
                    color: _loaded ? _ok : _textLo,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_status,
                        style: const TextStyle(
                            color: _textLo, fontSize: 12.5, height: 1.4)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _label('Prompt'),
            const SizedBox(height: 8),
            TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: _textHi, fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: _card,
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: _generating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(_generating ? 'Generando…' : 'Generar'),
                onPressed: (!_loaded || _generating) ? null : _generate,
              ),
            ),
            if (_stats.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _accent.withValues(alpha: 0.4)),
                ),
                child: Text(_stats,
                    style: const TextStyle(
                        color: _accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace')),
              ),
            ],
            if (_output.isNotEmpty) ...[
              const SizedBox(height: 14),
              _label('Salida'),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: _box(),
                child: SelectableText(_output,
                    style: const TextStyle(
                        color: _textHi, fontSize: 14, height: 1.5)),
              ),
            ],
            const SizedBox(height: 24),
            _label('Servidor OpenAI local'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _serverRunning ? Icons.cloud_done : Icons.cloud_off,
                        size: 16,
                        color: _serverRunning ? _ok : _textLo,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _serverMsg.isEmpty ? 'Detenido.' : _serverMsg,
                          style: const TextStyle(
                              color: _textLo, fontSize: 12.5, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _serverRunning ? _card : _accent,
                            foregroundColor:
                                _serverRunning ? _textLo : Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: Icon(
                              _serverRunning
                                  ? Icons.stop
                                  : Icons.play_arrow_rounded,
                              size: 18),
                          label:
                              Text(_serverRunning ? 'Detener' : 'Iniciar servidor'),
                          onPressed: _serverBusy
                              ? null
                              : (_serverRunning ? _stopServer : _startServer),
                        ),
                      ),
                      if (_serverRunning) ...[
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _accent,
                            side: const BorderSide(color: _border),
                            padding: const EdgeInsets.symmetric(
                                vertical: 11, horizontal: 14),
                          ),
                          icon: const Icon(Icons.bolt, size: 16),
                          label: const Text('Probar'),
                          onPressed: _serverBusy ? null : _testServer,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  BoxDecoration _box() => BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      );

  Widget _label(String t) => Text(
        t.toUpperCase(),
        style: const TextStyle(
            color: _textLo,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6),
      );
}
