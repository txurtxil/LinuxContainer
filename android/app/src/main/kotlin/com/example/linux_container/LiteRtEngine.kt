package com.example.linux_container

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Tool
import com.google.ai.edge.litertlm.ToolParam
import com.google.ai.edge.litertlm.ToolSet
import com.google.ai.edge.litertlm.tool
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
    @Volatile
    var cacheDirPath: String? = null
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
                visionBackend = backend,
                cacheDir = context.cacheDir.path,
                // Limita el KV-cache (contexto) para no agotar la RAM.
                // 3072 da margen al system prompt de CodeAgent (tools +
                // formato ReAct, ~2649 tokens) sin volver al problema de
                // memoria que causaba 32K por defecto (TTFT 34s + OOM).
                // Si esto provoca un error de forma de tensor al generar,
                // prueba 2048 o quita la linea (default del modelo).
                maxNumTokens = 4096,
            )
            val e = Engine(config)
            e.initialize()
            engine = e
            loadedPath = modelPath
            loadedGpu = useGpu
            cacheDirPath = context.cacheDir.path
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
     * Generacion con imagen usando el motor de PRODUCCION (el mismo que
     * el chat de texto, no uno temporal). Requiere visionBackend
     * configurado en load() y que el modelo cargado soporte multimodalidad
     * (confirmado con Gemma 4 E2B/.litertlm).
     */
    fun generateWithImage(
        text: String,
        imagePath: String,
        temperature: Float = 0.8f,
        topK: Int = 40,
        topP: Float = 0.95f
    ): Pair<String?, String> {
        val eng = engine ?: return Pair("Modelo no cargado", "")
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
                val response = conversation.sendMessage(
                    Contents.of(
                        Content.Text(text),
                        Content.ImageFile(imagePath),
                    )
                )
                Pair(null, response.toString())
            }
        } catch (e: Throwable) {
            Pair("Error al generar con imagen: ${e.message}", "")
        } finally {
            genLock.unlock()
        }
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

    /**
     * TEST AISLADO: comprueba si esta version de litertlm-android soporta
     * imagenes con el modelo actual. Crea su propio Engine TEMPORAL (no
     * toca el motor de produccion usado por el chat de texto), hace UNA
     * generacion con imagen, y lo cierra. Devuelve (error, texto).
     */
    /**
     * ToolSet de prueba minimo para el test aislado de function calling.
     * Una sola herramienta trivial (sumar dos enteros) para confirmar si
     * el modelo cargado reconoce y llama herramientas nativas de LiteRT-LM,
     * en vez de responder solo en texto plano.
     */
    private class TestSumToolSet : ToolSet {
        @Tool(description = "Suma dos numeros enteros y devuelve el resultado")
        fun sumar(
            @ToolParam(description = "Primer numero entero") a: Int,
            @ToolParam(description = "Segundo numero entero") b: Int
        ): Map<String, Any> {
            return mapOf("resultado" to (a + b))
        }
    }

    fun testFunctionCalling(context: Context, modelPath: String, useGpu: Boolean = true): Pair<String?, String> {
        return try {
            val testConfig = EngineConfig(
                modelPath = modelPath,
                backend = if (useGpu) Backend.GPU() else Backend.CPU(),
                cacheDir = context.cacheDir.path,
                maxNumTokens = 4096,
            )
            val testEngine = Engine(testConfig)
            testEngine.initialize()
            try {
                testEngine.createConversation(
                    ConversationConfig(
                        tools = listOf(tool(TestSumToolSet())),
                        automaticToolCalling = false,
                    )
                ).use { conversation ->
                    val response = conversation.sendMessage(
                        "Cuanto es 47 mas 89? Usa la herramienta sumar para calcularlo, no lo calcules tu mismo."
                    )
                    val result = if (response.toolCalls.isNotEmpty()) {
                        val call = response.toolCalls[0]
                        "FUNCIONA: llamo a '${call.name}' con argumentos: ${call.arguments}"
                    } else {
                        "NO_FUNCIONA (texto plano, sin tool call): ${response.toString()}"
                    }
                    Pair(null, result)
                }
            } finally {
                testEngine.close()
            }
        } catch (e: Throwable) {
            Pair("ERROR: ${e.javaClass.simpleName}: ${e.message}", "")
        }
    }

    /**
     * ToolSet minimo para probar FunctionGemma Mobile Actions -- este
     * modelo concreto solo fue afinado sobre un set cerrado de funciones
     * (turn_on_flashlight, create_calendar_event, create_contact...), asi
     * que reutilizamos una de las SUYAS en vez de una generica como
     * TestSumToolSet.
     */
    private class TestFlashlightToolSet : ToolSet {
        @Tool(description = "Enciende la linterna del dispositivo")
        fun turnOnFlashlight(): Map<String, Any> {
            return mapOf("status" to "ok")
        }
    }

    /**
     * Test especifico para FunctionGemma: incluye el "Essential System
     * Prompt" que la documentacion pide para activar su logica de
     * function calling, ademas de una tool que el modelo si conoce.
     * NOTA: el system prompt exacto de Google esta truncado en la
     * documentacion publica que encontramos; este es el mejor intento de
     * reconstruccion, no una copia verificada al 100%.
     */
    fun testFunctionGemmaFlashlight(context: Context, modelPath: String, useGpu: Boolean = true): Pair<String?, String> {
        return try {
            val testConfig = EngineConfig(
                modelPath = modelPath,
                backend = if (useGpu) Backend.GPU() else Backend.CPU(),
                cacheDir = context.cacheDir.path,
                maxNumTokens = 4096,
            )
            val testEngine = Engine(testConfig)
            testEngine.initialize()
            try {
                testEngine.createConversation(
                    ConversationConfig(
                        systemInstruction = Contents.of(Content.Text("You are a model that can do function calling with the following functions.")),
                        tools = listOf(tool(TestFlashlightToolSet())),
                        automaticToolCalling = false,
                    )
                ).use { conversation ->
                    val response = conversation.sendMessage("Enciende la linterna")
                    val result = if (response.toolCalls.isNotEmpty()) {
                        val call = response.toolCalls[0]
                        "FUNCIONA: llamo a '${call.name}' con argumentos: ${call.arguments}"
                    } else {
                        "NO_FUNCIONA (texto plano, sin tool call): ${response.toString()}"
                    }
                    Pair(null, result)
                }
            } finally {
                testEngine.close()
            }
        } catch (e: Throwable) {
            Pair("ERROR: ${e.javaClass.simpleName}: ${e.message}", "")
        }
    }

    fun testFunctionGemmaRaw(context: Context, modelPath: String, useGpu: Boolean = true): Pair<String?, String> {
        return try {
            val testConfig = EngineConfig(
                modelPath = modelPath,
                backend = if (useGpu) Backend.GPU() else Backend.CPU(),
                cacheDir = context.cacheDir.path,
                maxNumTokens = 4096,
            )
            val testEngine = Engine(testConfig)
            testEngine.initialize()
            try {
                testEngine.createConversation().use { conversation ->
                    val prompt = "<start_of_turn>developer\n" +
                        "You are a model that can do function calling with the following functions\n" +
                        "<start_function_declaration>declaration:turn_on_flashlight{description:\"Turns on the device flashlight\"}<end_function_declaration>\n" +
                        "<end_of_turn>\n" +
                        "<start_of_turn>user\n" +
                        "Turn on the flashlight\n" +
                        "<end_of_turn>\n" +
                        "<start_of_turn>model\n"
                    val response = conversation.sendMessage(prompt)
                    Pair(null, response.toString())
                }
            } finally {
                testEngine.close()
            }
        } catch (e: Throwable) {
            Pair("ERROR: ${e.javaClass.simpleName}: ${e.message}", "")
        }
    }

    fun testGemma4NativeToolCall(context: Context, modelPath: String, useGpu: Boolean = true): Pair<String?, String> {
        return try {
            val testConfig = EngineConfig(
                modelPath = modelPath,
                backend = if (useGpu) Backend.GPU() else Backend.CPU(),
                cacheDir = context.cacheDir.path,
                maxNumTokens = 4096,
            )
            val testEngine = Engine(testConfig)
            testEngine.initialize()
            try {
                testEngine.createConversation().use { conversation ->
                    val prompt = "<|turn>system\n" +
                        "<|tool>declaration:turn_on_flashlight{description:<|\"|>Turns on the device flashlight<|\"|>}<tool|><turn|>\n" +
                        "<|turn>user\n" +
                        "Turn on the flashlight<turn|>\n" +
                        "<|turn>model\n" +
                        "<|channel>thought\n<channel|>"
                    val response = conversation.sendMessage(prompt)
                    Pair(null, response.toString())
                }
            } finally {
                testEngine.close()
            }
        } catch (e: Throwable) {
            Pair("ERROR: ${e.javaClass.simpleName}: ${e.message}", "")
        }
    }

    fun testImageSupport(context: Context, modelPath: String, imagePath: String): Pair<String?, String> {
        return try {
            val testConfig = EngineConfig(
                modelPath = modelPath,
                backend = Backend.GPU(),
                visionBackend = Backend.GPU(),
                cacheDir = context.cacheDir.path,
                maxNumTokens = 4096,
            )
            val testEngine = Engine(testConfig)
            testEngine.initialize()
            try {
                testEngine.createConversation().use { conversation ->
                    val response = conversation.sendMessage(
                        Contents.of(
                            Content.Text("Describe brevemente esta imagen."),
                            Content.ImageFile(imagePath),
                        )
                    )
                    Pair(null, response.toString())
                }
            } finally {
                testEngine.close()
            }
        } catch (e: Throwable) {
            Pair("ERROR: ${e.javaClass.simpleName}: ${e.message}", "")
        }
    }
}
