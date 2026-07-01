package com.example.linux_container

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import java.util.concurrent.CountDownLatch
import java.util.concurrent.locks.ReentrantLock

/**
 * Motor singleton de inferencia on-device con LiteRT-LM (GPU/CPU).
 *
 * Sustituto de MediaPipeEngine para la v1.3: usa el formato .litertlm y la
 * API Engine + Conversation de LiteRT-LM, que soporta Gemma 4, function
 * calling nativo y multimodalidad.
 *
 * Mantiene EXACTAMENTE la misma interfaz publica que MediaPipeEngine
 * (load / generate / generateBlocking / sizeInTokens / isLoaded /
 * loadedPath / loadedGpu / close) para que MediaPipeServer no cambie.
 */
object LiteRtEngine {
    private var engine: Engine? = null

    @Volatile
    var loadedPath: String? = null
        private set

    @Volatile
    var loadedGpu: Boolean = true
        private set

    private val genLock = ReentrantLock()

    val isLoaded: Boolean get() = engine != null

    /**
     * Carga un modelo .litertlm. Devuelve null si OK, o el mensaje de error.
     * engine.initialize() puede tardar 10s+ en modelos grandes; el llamante
     * debe ejecutarlo fuera del hilo de UI.
     */
    @Synchronized
    fun load(context: Context, modelPath: String, useGpu: Boolean): String? {
        return try {
            if (engine != null && loadedPath == modelPath && loadedGpu == useGpu) {
                return null
            }
            closeInternal()

            val backend = if (useGpu) Backend.GPU() else Backend.CPU()
            val config = EngineConfig(
                modelPath = modelPath,
                backend = backend,
                cacheDir = context.cacheDir.path,
            )
            val e = Engine(config)
            e.initialize()
            engine = e
            loadedPath = modelPath
            loadedGpu = useGpu
            null
        } catch (e: Throwable) {
            "Error al cargar el modelo: ${e.message}"
        }
    }

    /**
     * Generacion en streaming. Llama a onPartial(token, done) por cada trozo.
     * Bloquea el hilo llamante hasta terminar; serializada por un lock.
     * Crea una conversacion efimera por generacion (stateless).
     */
    fun generate(
        prompt: String,
        temperature: Float = 0.8f,
        topK: Int = 40,
        topP: Float = 0.95f,
        onPartial: (String, Boolean) -> Unit
    ): String? {
        val eng = engine ?: return "Modelo no cargado"
        genLock.lock()
        return try {
            val convConfig = ConversationConfig(
                samplerConfig = SamplerConfig(
                    topK = topK,
                    topP = topP.toDouble(),
                    temperature = temperature.toDouble(),
                ),
            )
            eng.createConversation(convConfig).use { conversation ->
                // Llamada SINCRONA: bloquea hasta la respuesta completa.
                // Mas robusta que el callback async (evita deadlocks nativos).
                val response = conversation.sendMessage(prompt)
                val text = response.toString()
                if (text.isNotEmpty()) onPartial(text, false)
                onPartial("", true)
                null
            }
        } catch (e: Throwable) {
            "Error al generar: ${e.message}"
        } finally {
            genLock.unlock()
        }
    }

    /** Generacion bloqueante que devuelve (error, textoCompleto). */
    fun generateBlocking(
        prompt: String,
        temperature: Float = 0.8f,
        topK: Int = 40,
        topP: Float = 0.95f
    ): Pair<String?, String> {
        val sb = StringBuilder()
        val err = generate(prompt, temperature, topK, topP) { token, _ ->
            if (token.isNotEmpty()) sb.append(token)
        }
        return Pair(err, sb.toString())
    }

    /**
     * LiteRT-LM no expone contador de tokens publico estable, aproximamos.
     * Solo se usa para metricas de usage, no afecta a la generacion.
     */
    fun sizeInTokens(text: String): Int {
        if (text.isEmpty()) return 0
        return (text.length / 4).coerceAtLeast(1)
    }

    @Synchronized
    fun close() {
        closeInternal()
    }

    private fun closeInternal() {
        try {
            engine?.close()
        } catch (_: Throwable) {
        }
        engine = null
        loadedPath = null
    }
}
