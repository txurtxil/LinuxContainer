// lib/src/agent/agent_services.dart
// Gestión de fuentes LLM para XTR Terminal
// Gemini actualizado: 3.5-flash (nuevo flagship free), 2.5-flash
// GPU local: SIEMPRE MediaPipe (puerto 8090) — sin CPU fallback

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────
// Modelos de datos
// ─────────────────────────────────────────────────────────────

enum LlmSourceType {
  groq,
  gemini,
  cerebras,
  openRouter,
  gpuLocal,   // MediaPipe GPU — siempre local
  custom,
}

class LlmSource {
  final LlmSourceType type;
  final String        name;
  final String        apiKey;
  final String        model;
  final String?       baseUrl; // solo para custom
  final bool          isEnabled;

  const LlmSource({
    required this.type,
    required this.name,
    required this.apiKey,
    required this.model,
    this.baseUrl,
    this.isEnabled = true,
  });

  LlmSource copyWith({
    String? apiKey,
    String? model,
    String? baseUrl,
    bool?   isEnabled,
  }) => LlmSource(
    type:      type,
    name:      name,
    apiKey:    apiKey    ?? this.apiKey,
    model:     model     ?? this.model,
    baseUrl:   baseUrl   ?? this.baseUrl,
    isEnabled: isEnabled ?? this.isEnabled,
  );

  Map<String, dynamic> toJson() => {
    'type':      type.name,
    'name':      name,
    'apiKey':    apiKey,
    'model':     model,
    'baseUrl':   baseUrl,
    'isEnabled': isEnabled,
  };

  factory LlmSource.fromJson(Map<String, dynamic> j) => LlmSource(
    type:      LlmSourceType.values.firstWhere(
                 (e) => e.name == j['type'],
                 orElse: () => LlmSourceType.custom),
    name:      j['name'] as String,
    apiKey:    j['apiKey'] as String? ?? '',
    model:     j['model'] as String,
    baseUrl:   j['baseUrl'] as String?,
    isEnabled: j['isEnabled'] as bool? ?? true,
  );
}

// ─────────────────────────────────────────────────────────────
// Catálogo de modelos por fuente
// ─────────────────────────────────────────────────────────────

class ModelCatalog {

  // ── Groq (tool-calling perfecto) ──────────────────────────
  static const groqModels = [
    'llama-3.1-8b-instant',     // ← recomendado tool-calling
    'llama-3.3-70b-versatile',
    'llama-3.1-70b-versatile',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
  ];

  // ── Gemini (actualizado junio 2026) ───────────────────────
  // Tier gratuito: gemini-3.5-flash, gemini-2.5-flash,
  //                gemini-2.5-flash-lite, gemini-3-flash-preview
  // Pro: solo paid
  static const geminiModels = [
    'gemini-3.5-flash',         // ← nuevo flagship (mayo 2026), FREE tier
    'gemini-2.5-flash',         // ← probado y funcional, FREE tier
    'gemini-2.5-flash-lite',    // más barato/rápido
    'gemini-3-flash',           // gen anterior
    'gemini-3.1-flash-lite',    // económico reciente
  ];

  // ── Cerebras ──────────────────────────────────────────────
  static const cerebrasModels = [
    'llama3.1-8b',
    'llama3.1-70b',
    'llama-4-scout-17b-16e-instruct',
  ];

  // ── OpenRouter ────────────────────────────────────────────
  static const openRouterModels = [
    'meta-llama/llama-3.1-8b-instruct:free',
    'google/gemini-3.5-flash',
    'google/gemini-2.5-flash',
    'mistralai/mistral-7b-instruct:free',
    'anthropic/claude-sonnet-4-6',
    'deepseek/deepseek-chat',
  ];

  // ── GPU Local (MediaPipe .task) ────────────────────────────
  // Sin modelos listados — el usuario importa el .task desde la app
  // Soporta: gemma3-1b-it-int4.task, gemma3-4b-it-int4.task
  static const gpuLocalModels = [
    'gemma3-local-gpu',   // placeholder — el modelo real es el .task cargado
  ];

  static List<String> forType(LlmSourceType type) {
    switch (type) {
      case LlmSourceType.groq:       return groqModels;
      case LlmSourceType.gemini:     return geminiModels;
      case LlmSourceType.cerebras:   return cerebrasModels;
      case LlmSourceType.openRouter: return openRouterModels;
      case LlmSourceType.gpuLocal:   return gpuLocalModels;
      case LlmSourceType.custom:     return [];
    }
  }
}

// ─────────────────────────────────────────────────────────────
// URLs base por fuente
// ─────────────────────────────────────────────────────────────

class ApiEndpoints {
  static const groq       = 'https://api.groq.com/openai/v1';
  static const gemini     = 'https://generativelanguage.googleapis.com/v1beta/openai';
  static const cerebras   = 'https://api.cerebras.ai/v1';
  static const openRouter = 'https://openrouter.ai/api/v1';
  static const gpuLocal   = 'http://127.0.0.1:8090/v1'; // MediaPipe NanoHTTPD

  static String forSource(LlmSource source) {
    switch (source.type) {
      case LlmSourceType.groq:       return groq;
      case LlmSourceType.gemini:     return gemini;
      case LlmSourceType.cerebras:   return cerebras;
      case LlmSourceType.openRouter: return openRouter;
      case LlmSourceType.gpuLocal:   return gpuLocal;
      case LlmSourceType.custom:     return source.baseUrl ?? '';
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Servicio de persistencia
// ─────────────────────────────────────────────────────────────

class AgentSourceService extends ChangeNotifier {

  static const _prefKey        = 'llm_sources_v2';
  static const _prefActiveKey  = 'llm_active_source';

  List<LlmSource> _sources     = [];
  LlmSource?      _activeSource;

  List<LlmSource> get sources       => _sources;
  LlmSource?      get activeSource  => _activeSource;

  // ── Fuentes por defecto ──────────────────────────────────
  static List<LlmSource> get defaults => [
    const LlmSource(
      type:    LlmSourceType.groq,
      name:    'Groq',
      apiKey:  '',
      model:   'llama-3.1-8b-instant',
    ),
    const LlmSource(
      type:    LlmSourceType.gemini,
      name:    'Gemini',
      apiKey:  '',
      model:   'gemini-3.5-flash',       // ← actualizado a 3.5
    ),
    const LlmSource(
      type:    LlmSourceType.cerebras,
      name:    'Cerebras',
      apiKey:  '',
      model:   'llama3.1-8b',
    ),
    const LlmSource(
      type:    LlmSourceType.openRouter,
      name:    'OpenRouter',
      apiKey:  '',
      model:   'meta-llama/llama-3.1-8b-instruct:free',
    ),
    const LlmSource(
      type:    LlmSourceType.gpuLocal,
      name:    'GPU Local (MediaPipe)',
      apiKey:  'local',
      model:   'gemma3-local-gpu',
    ),
    const LlmSource(
      type:    LlmSourceType.custom,
      name:    'Personalizado',
      apiKey:  '',
      model:   '',
      baseUrl: '',
    ),
  ];

  // ── Cargar desde SharedPreferences ──────────────────────
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_prefKey);

    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => LlmSource.fromJson(e as Map<String, dynamic>))
            .toList();
        _sources = list;
      } catch (_) {
        _sources = List.from(defaults);
      }
    } else {
      _sources = List.from(defaults);
    }

    // Restaurar fuente activa
    final activeType = prefs.getString(_prefActiveKey);
    if (activeType != null) {
      _activeSource = _sources.firstWhere(
        (s) => s.type.name == activeType,
        orElse: () => _sources.first,
      );
    }

    notifyListeners();
  }

  // ── Guardar ──────────────────────────────────────────────
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_sources.map((s) => s.toJson()).toList()));
    if (_activeSource != null) {
      await prefs.setString(_prefActiveKey, _activeSource!.type.name);
    }
  }

  // ── Actualizar fuente ────────────────────────────────────
  Future<void> updateSource(LlmSourceType type, {
    String? apiKey,
    String? model,
    String? baseUrl,
    bool?   isEnabled,
  }) async {
    final idx = _sources.indexWhere((s) => s.type == type);
    if (idx == -1) return;

    _sources[idx] = _sources[idx].copyWith(
      apiKey:    apiKey,
      model:     model,
      baseUrl:   baseUrl,
      isEnabled: isEnabled,
    );
    await _save();
    notifyListeners();
  }

  // ── Seleccionar fuente activa ────────────────────────────
  Future<void> setActive(LlmSourceType type) async {
    _activeSource = _sources.firstWhere(
      (s) => s.type == type,
      orElse: () => _sources.first,
    );
    await _save();
    notifyListeners();
  }

  // ── Obtener URL base + headers para una fuente ───────────
  static Map<String, String> headersFor(LlmSource source) {
    final base = {
      'Content-Type': 'application/json',
    };

    switch (source.type) {
      case LlmSourceType.groq:
      case LlmSourceType.cerebras:
      case LlmSourceType.openRouter:
        return {...base, 'Authorization': 'Bearer ${source.apiKey}'};

      case LlmSourceType.gemini:
        // Gemini usa OpenAI-compatible con Bearer
        return {...base, 'Authorization': 'Bearer ${source.apiKey}'};

      case LlmSourceType.gpuLocal:
        // Sin auth — servidor local
        return base;

      case LlmSourceType.custom:
        if (source.apiKey.isNotEmpty) {
          return {...base, 'Authorization': 'Bearer ${source.apiKey}'};
        }
        return base;
    }
  }

  // ── Test de conexión ─────────────────────────────────────
  Future<({bool ok, String message})> testSource(LlmSource source) async {
    try {
      if (source.type == LlmSourceType.gpuLocal) {
        // Para GPU local, verificamos el endpoint de health
        final url = Uri.parse('${ApiEndpoints.gpuLocal}/models');
        final resp = await http.get(url).timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          return (ok: true, message: 'MediaPipe GPU activo ✓');
        }
        return (ok: false, message: 'MediaPipe no responde (¿modelo cargado?)');
      }

      final baseUrl = ApiEndpoints.forSource(source);
      if (baseUrl.isEmpty) {
        return (ok: false, message: 'URL base no configurada');
      }

      final url  = Uri.parse('$baseUrl/chat/completions');
      final body = jsonEncode({
        'model': source.model,
        'messages': [{'role': 'user', 'content': 'ping'}],
        'max_tokens': 5,
      });

      final resp = await http.post(
        url,
        headers: headersFor(source),
        body: body,
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        return (ok: true, message: 'Conexión OK ✓');
      }
      return (ok: false, message: 'HTTP ${resp.statusCode}');
    } catch (e) {
      return (ok: false, message: e.toString().split('\n').first);
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Helper: detectar si una fuente es GPU local
// (usado en agent_server.py para bypass de tool-calling)
// ─────────────────────────────────────────────────────────────

extension LlmSourceExt on LlmSource {
  bool get isGpuLocal => type == LlmSourceType.gpuLocal;
  bool get supportsToolCalling => !isGpuLocal;

  String get displayModel {
    if (type == LlmSourceType.gpuLocal) return 'GPU MediaPipe (.task)';
    return model;
  }
}
