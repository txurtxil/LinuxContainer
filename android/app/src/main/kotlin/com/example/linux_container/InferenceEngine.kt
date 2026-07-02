package com.example.linux_container

import android.content.Context

/**
 * Router de motor de inferencia (v1.3).
 *
 * Detecta el formato del modelo por su extension y delega al motor correcto:
 *   - .task      -> MediaPipeEngine  (Gemma 3, Gemma 3n)
 *   - .litertlm  -> LiteRtEngine     (Gemma 4, Gemma 3n, multimodal, tools)
 *
 * Expone la MISMA interfaz que ambos motores, asi que MediaPipeServer y
 * MainActivity solo tienen que cambiar "MediaPipeEngine." por
 * "InferenceEngine." y todo sigue funcionando con ambos formatos.
 *
 * Solo un motor esta activo a la vez (se libera el otro al cargar).
 */
object InferenceEngine {

    enum class Kind { MEDIAPIPE, LITERTLM, NONE }

    @Volatile
    var activeKind: Kind = Kind.NONE
        private set

    private fun kindForPath(path: String): Kind {
        val lower = path.lowercase()
        return when {
            lower.endsWith(".litertlm") -> Kind.LITERTLM
            lower.endsWith(".task")     -> Kind.MEDIAPIPE
            // Por defecto asumimos .task (compatibilidad con v1.2)
            else -> Kind.MEDIAPIPE
        }
    }

    val isLoaded: Boolean
        get() = when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.isLoaded
            Kind.LITERTLM  -> LiteRtEngine.isLoaded
            Kind.NONE      -> false
        }

    val loadedPath: String?
        get() = when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.loadedPath
            Kind.LITERTLM  -> LiteRtEngine.loadedPath
            Kind.NONE      -> null
        }

    val loadedGpu: Boolean
        get() = when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.loadedGpu
            Kind.LITERTLM  -> LiteRtEngine.loadedGpu
            Kind.NONE      -> true
        }

    /** Nombre legible del backend activo, para logs/UI. */
    val engineLabel: String
        get() = when (activeKind) {
            Kind.MEDIAPIPE -> "MediaPipe"
            Kind.LITERTLM  -> "LiteRT-LM"
            Kind.NONE      -> "ninguno"
        }

    @Synchronized
    fun load(context: Context, modelPath: String, useGpu: Boolean): String? {
        val target = kindForPath(modelPath)
        // Liberar el motor anterior si era de otro tipo.
        if (activeKind != Kind.NONE && activeKind != target) {
            closeInternal()
        }
        val err = when (target) {
            Kind.MEDIAPIPE -> MediaPipeEngine.load(context, modelPath, useGpu)
            Kind.LITERTLM  -> LiteRtEngine.load(context, modelPath, useGpu)
            Kind.NONE      -> "Formato de modelo desconocido"
        }
        if (err == null) activeKind = target
        return err
    }

    fun generate(
        prompt: String,
        temperature: Float = 0.8f,
        topK: Int = 40,
        topP: Float = 0.95f,
        onPartial: (String, Boolean) -> Unit
    ): String? {
        return when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.generate(prompt, temperature, topK, topP, onPartial)
            Kind.LITERTLM  -> LiteRtEngine.generate(prompt, temperature, topK, topP, onPartial)
            Kind.NONE      -> "Modelo no cargado"
        }
    }

    fun generateBlocking(
        prompt: String,
        temperature: Float = 0.8f,
        topK: Int = 40,
        topP: Float = 0.95f
    ): Pair<String?, String> {
        return when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.generateBlocking(prompt, temperature, topK, topP)
            Kind.LITERTLM  -> LiteRtEngine.generateBlocking(prompt, temperature, topK, topP)
            Kind.NONE      -> Pair("Modelo no cargado", "")
        }
    }

    fun sizeInTokens(text: String): Int {
        return when (activeKind) {
            Kind.MEDIAPIPE -> MediaPipeEngine.sizeInTokens(text)
            Kind.LITERTLM  -> LiteRtEngine.sizeInTokens(text)
            Kind.NONE      -> 0
        }
    }

    @Synchronized
    fun close() {
        closeInternal()
    }

    private fun closeInternal() {
        try { MediaPipeEngine.close() } catch (_: Throwable) {}
        try { LiteRtEngine.close() } catch (_: Throwable) {}
        activeKind = Kind.NONE
    }
}
