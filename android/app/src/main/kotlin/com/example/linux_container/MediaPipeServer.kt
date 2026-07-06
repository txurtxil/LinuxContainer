package com.example.linux_container

import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream

/**
 * Servidor HTTP local compatible con la API de OpenAI, sobre MediaPipeEngine.
 * Expone /v1/chat/completions (stream y no-stream), /v1/models y /health en
 * 127.0.0.1:<port>, accesible desde el agente que corre en el proot.
 *
 * Usa NanoHTTPD (ligero y compatible con Android).
 */
object MediaPipeServer {

    private var httpd: Server? = null

    @Volatile
    var port: Int = 8090
        private set

    val isRunning: Boolean get() = httpd?.isAlive == true

    fun start(port: Int): String? {
        return try {
            if (httpd?.isAlive == true) return null
            this.port = port
            val s = Server(port)
            s.start(300000, false)  // 5 min: margen para primera inferencia con imagen
            httpd = s
            null
        } catch (e: Throwable) {
            "Error al iniciar servidor: ${e.message}"
        }
    }

    fun stop() {
        try {
            httpd?.stop()
        } catch (_: Throwable) {
        }
        httpd = null
    }

    private fun modelId(): String =
        InferenceEngine.loadedPath?.substringAfterLast('/') ?: "mediapipe-local"

    private class Server(port: Int) : NanoHTTPD("127.0.0.1", port) {

        override fun serve(session: IHTTPSession): Response {
            return try {
                when (session.uri) {
                    "/health" -> json(Response.Status.OK, JSONObject().put("status", "ok"))
                    "/v1/models" -> handleModels()
                    "/v1/chat/completions" -> handleChat(session)
                    else -> json(Response.Status.NOT_FOUND, errObj("no encontrado"))
                }
            } catch (e: Throwable) {
                json(Response.Status.INTERNAL_ERROR, errObj(e.message ?: "error interno"))
            }
        }

        private fun handleModels(): Response {
            val data = JSONArray().put(
                JSONObject().put("id", modelId()).put("object", "model")
                    .put("owned_by", "local")
            )
            return json(
                Response.Status.OK,
                JSONObject().put("object", "list").put("data", data)
            )
        }

        private fun handleChat(session: IHTTPSession): Response {
            if (session.method != Method.POST) {
                return json(Response.Status.METHOD_NOT_ALLOWED, errObj("Método no permitido"))
            }
            val files = HashMap<String, String>()
            session.parseBody(files)
            val body = files["postData"] ?: "{}"
            val req = JSONObject(body)
            val messages = req.optJSONArray("messages") ?: JSONArray()
            val stream = req.optBoolean("stream", false)
            val temperature = req.optDouble("temperature", 0.8).toFloat()
            val topP = req.optDouble("top_p", 0.95).toFloat()
            val topK = req.optInt("top_k", 40)
            val prompt = buildGemmaPrompt(messages)

            if (!InferenceEngine.isLoaded) {
                return json(Response.Status.INTERNAL_ERROR,
                    errObj("El modelo no está cargado en el motor."))
            }
            val tools = req.optJSONArray("tools")
            if (tools != null && tools.length() > 0) {
                val toolPrompt = buildGemma4ToolPrompt(messages, tools)
                // Temperatura baja fija: la sintaxis de tool_call necesita
                // precision exacta, no creatividad. Ignoramos la temperatura
                // pedida por el cliente para este camino especifico.
                val (errT, outT) = InferenceEngine.generateBlocking(toolPrompt, 0.1f, topK, topP)
                if (errT != null) return json(Response.Status.INTERNAL_ERROR, errObj(errT))
                val parsed = parseGemma4ToolCall(outT)
                return if (parsed != null) toolCallResponseJson(parsed.first, parsed.second, toolPrompt)
                       else chatResponseJson(outT, toolPrompt)
            }
            val imageInfo = extractImageFromMessages(messages)
            if (imageInfo != null) {
                val (imgText, imagePath) = imageInfo
                val (err, out) = InferenceEngine.generateWithImage(imgText, imagePath, temperature, topK, topP)
                if (err != null) return json(Response.Status.INTERNAL_ERROR, errObj(err))
                return chatResponseJson(out, imgText)
            }
            return if (stream) streamChat(prompt, temperature, topK, topP)
            else blockingChat(prompt, temperature, topK, topP)
        }

        /** Convierte los mensajes OpenAI a la plantilla de turnos de Gemma. */
        private fun extractImageFromMessages(messages: JSONArray): Pair<String, String>? {
            for (i in messages.length() - 1 downTo 0) {
                val m = messages.getJSONObject(i)
                if (m.optString("role") != "user") continue
                val content = m.opt("content")
                if (content !is JSONArray) return null
                var text = ""
                var base64Data: String? = null
                for (j in 0 until content.length()) {
                    val part = content.getJSONObject(j)
                    when (part.optString("type")) {
                        "text" -> text = part.optString("text", "")
                        "image_url" -> {
                            val url = part.optJSONObject("image_url")?.optString("url") ?: ""
                            val marker = "base64,"
                            val idx = url.indexOf(marker)
                            if (idx >= 0) base64Data = url.substring(idx + marker.length)
                        }
                    }
                }
                if (base64Data == null) return null
                return try {
                    val bytes = android.util.Base64.decode(base64Data, android.util.Base64.DEFAULT)
                    val cacheDir = LiteRtEngine.cacheDirPath?.let { java.io.File(it) }
                    val tmpFile = java.io.File.createTempFile("xtr_img_", ".jpg", cacheDir)
                    tmpFile.writeBytes(bytes)
                    Pair(text, tmpFile.absolutePath)
                } catch (e: Throwable) {
                    null
                }
            }
            return null
        }

        private fun chatResponseJson(text: String, promptForUsage: String): Response {
            val msg = JSONObject().put("role", "assistant").put("content", text)
            val choice = JSONObject().put("index", 0).put("message", msg)
                .put("finish_reason", "stop")
            val pt = InferenceEngine.sizeInTokens(promptForUsage)
            val ct = InferenceEngine.sizeInTokens(text)
            val usage = JSONObject().put("prompt_tokens", pt)
                .put("completion_tokens", ct).put("total_tokens", pt + ct)
            val resp = JSONObject()
                .put("id", "chatcmpl-local")
                .put("object", "chat.completion")
                .put("created", System.currentTimeMillis() / 1000)
                .put("model", modelId())
                .put("choices", JSONArray().put(choice))
                .put("usage", usage)
            return json(Response.Status.OK, resp)
        }

        /** Construye las declaraciones de herramientas en el formato nativo
         *  de Gemma 4 (<|tool>declaration:...<tool|>) a partir del array
         *  "tools" estilo OpenAI que ya manda agent_server.py. */
        private fun buildToolDeclarations(tools: JSONArray): String {
            val sb = StringBuilder()
            for (i in 0 until tools.length()) {
                val fn = tools.getJSONObject(i).optJSONObject("function") ?: continue
                val name = fn.optString("name")
                val description = fn.optString("description")
                sb.append("<|tool>declaration:").append(name)
                    .append("{description:<|\"|>").append(description).append("<|\"|>")
                val params = fn.optJSONObject("parameters")
                val properties = params?.optJSONObject("properties")
                if (properties != null && properties.length() > 0) {
                    sb.append(",parameters:{properties:{")
                    val keys = properties.keys()
                    var first = true
                    while (keys.hasNext()) {
                        val key = keys.next()
                        val propDef = properties.getJSONObject(key)
                        val type = propDef.optString("type", "string")
                        val desc = propDef.optString("description", "")
                        if (!first) sb.append(",")
                        sb.append(key).append(":{type:<|\"|>").append(type)
                            .append("<|\"|>,description:<|\"|>").append(desc).append("<|\"|>}")
                        first = false
                    }
                    sb.append("},required:[")
                    val required = params?.optJSONArray("required")
                    if (required != null) {
                        for (j in 0 until required.length()) {
                            if (j > 0) sb.append(",")
                            sb.append("<|\"|>").append(required.getString(j)).append("<|\"|>")
                        }
                    }
                    sb.append("],type:<|\"|>object<|\"|>}")
                }
                sb.append("}<tool|>")
            }
            return sb.toString()
        }

        /** Prompt nativo de Gemma 4 con herramientas. SOLO soporta un turno
         *  simple (system+tools opcional + ultimo mensaje de usuario) por
         *  ahora -- historial multi-turno con tool_calls previos no probado
         *  todavia, pendiente de validacion empirica. */
        private fun buildGemma4ToolPrompt(messages: JSONArray, tools: JSONArray): String {
            val sb = StringBuilder()
            sb.append("<|turn>system\n")
            sb.append(buildToolDeclarations(tools))
            sb.append("<turn|>\n")
            var lastUserText = ""
            for (i in 0 until messages.length()) {
                val m = messages.getJSONObject(i)
                if (m.optString("role") == "user") lastUserText = m.optString("content")
            }
            sb.append("<|turn>user\n").append(lastUserText).append("<turn|>\n")
            sb.append("<|turn>model\n")
            sb.append("<|channel>thought\n<channel|>")
            return sb.toString()
        }

        /** Parsea <|tool_call>call:NOMBRE{args}<tool_call|> de la salida cruda.
         *  Soporta argumentos string y valores sueltos (numeros/booleanos);
         *  NO soporta objetos o arrays anidados dentro de los argumentos
         *  todavia -- pendiente de validar si Gemma 4 los genera asi. */
        private fun parseGemma4ToolCall(text: String): Pair<String, JSONObject>? {
            val callRegex = Regex("""<\|tool_call>call:(\w+)\{(.*?)\}<tool_call\|>""")
            val match = callRegex.find(text) ?: return null
            val name = match.groupValues[1]
            val argsRaw = match.groupValues[2]
            val argsJson = JSONObject()
            if (argsRaw.isNotBlank()) {
                val pairRegex = Regex("""(\w+):(?:<\|"\|>(.*?)<\|"\|>|([^,]+))""")
                for (pairMatch in pairRegex.findAll(argsRaw)) {
                    val key = pairMatch.groupValues[1]
                    val strVal = pairMatch.groupValues[2]
                    val bareVal = pairMatch.groupValues[3]
                    if (strVal.isNotEmpty()) argsJson.put(key, strVal)
                    else if (bareVal.isNotEmpty()) argsJson.put(key, bareVal.trim())
                }
            }
            return Pair(name, argsJson)
        }

        /** Respuesta estilo OpenAI con tool_calls, el mismo formato que
         *  agent_server.py ya entiende cuando habla con Groq. */
        private fun toolCallResponseJson(toolName: String, toolArgs: JSONObject, promptForUsage: String): Response {
            val functionObj = JSONObject().put("name", toolName).put("arguments", toolArgs.toString())
            val toolCallObj = JSONObject()
                .put("id", "call_" + System.currentTimeMillis())
                .put("type", "function")
                .put("function", functionObj)
            val msg = JSONObject().put("role", "assistant").put("content", JSONObject.NULL)
                .put("tool_calls", JSONArray().put(toolCallObj))
            val choice = JSONObject().put("index", 0).put("message", msg).put("finish_reason", "tool_calls")
            val pt = InferenceEngine.sizeInTokens(promptForUsage)
            val usage = JSONObject().put("prompt_tokens", pt).put("completion_tokens", 0).put("total_tokens", pt)
            val resp = JSONObject()
                .put("id", "chatcmpl-local")
                .put("object", "chat.completion")
                .put("created", System.currentTimeMillis() / 1000)
                .put("model", modelId())
                .put("choices", JSONArray().put(choice))
                .put("usage", usage)
            return json(Response.Status.OK, resp)
        }

        private fun buildGemmaPrompt(messages: JSONArray): String {
            val sb = StringBuilder()
            var pendingSystem = ""
            for (i in 0 until messages.length()) {
                val m = messages.getJSONObject(i)
                val role = m.optString("role")
                val content = m.optString("content")
                when (role) {
                    "system" -> {
                        pendingSystem +=
                            (if (pendingSystem.isEmpty()) "" else "\n") + content
                    }
                    "user" -> {
                        val text = if (pendingSystem.isNotEmpty()) {
                            val t = "$pendingSystem\n\n$content"
                            pendingSystem = ""
                            t
                        } else {
                            content
                        }
                        sb.append("<start_of_turn>user\n").append(text)
                            .append("<end_of_turn>\n")
                    }
                    "assistant" -> {
                        sb.append("<start_of_turn>model\n").append(content)
                            .append("<end_of_turn>\n")
                    }
                    "tool" -> {
                        sb.append("<start_of_turn>user\n")
                            .append("[resultado de herramienta] ").append(content)
                            .append("<end_of_turn>\n")
                    }
                }
            }
            if (pendingSystem.isNotEmpty()) {
                sb.append("<start_of_turn>user\n").append(pendingSystem)
                    .append("<end_of_turn>\n")
            }
            sb.append("<start_of_turn>model\n")
            return sb.toString()
        }

        private fun blockingChat(
            prompt: String, temp: Float, topK: Int, topP: Float
        ): Response {
            val (err, text) = InferenceEngine.generateBlocking(prompt, temp, topK, topP)
            if (err != null) return json(Response.Status.INTERNAL_ERROR, errObj(err))
            val msg = JSONObject().put("role", "assistant").put("content", text)
            val choice = JSONObject().put("index", 0).put("message", msg)
                .put("finish_reason", "stop")
            val pt = InferenceEngine.sizeInTokens(prompt)
            val ct = InferenceEngine.sizeInTokens(text)
            val usage = JSONObject().put("prompt_tokens", pt)
                .put("completion_tokens", ct).put("total_tokens", pt + ct)
            val resp = JSONObject()
                .put("id", "chatcmpl-local")
                .put("object", "chat.completion")
                .put("created", System.currentTimeMillis() / 1000)
                .put("model", modelId())
                .put("choices", JSONArray().put(choice))
                .put("usage", usage)
            return json(Response.Status.OK, resp)
        }

        private fun streamChat(
            prompt: String, temp: Float, topK: Int, topP: Float
        ): Response {
            val pin = PipedInputStream(64 * 1024)
            val pout = PipedOutputStream(pin)
            val model = modelId()
            val id = "chatcmpl-local"
            Thread {
                try {
                    val err = InferenceEngine.generate(prompt, temp, topK, topP) { token, done ->
                        if (token.isNotEmpty()) {
                            val delta = JSONObject().put("content", token)
                            val choice = JSONObject().put("index", 0).put("delta", delta)
                            val chunk = JSONObject().put("id", id)
                                .put("object", "chat.completion.chunk")
                                .put("model", model)
                                .put("choices", JSONArray().put(choice))
                            writeSse(pout, chunk.toString())
                        }
                        if (done) {
                            val choice = JSONObject().put("index", 0)
                                .put("delta", JSONObject())
                                .put("finish_reason", "stop")
                            val chunk = JSONObject().put("id", id)
                                .put("object", "chat.completion.chunk")
                                .put("model", model)
                                .put("choices", JSONArray().put(choice))
                            writeSse(pout, chunk.toString())
                            writeSse(pout, "[DONE]")
                        }
                    }
                    if (err != null) {
                        writeSse(pout, JSONObject().put(
                            "error", JSONObject().put("message", err)).toString())
                    }
                } catch (e: Throwable) {
                    try {
                        writeSse(pout, JSONObject().put(
                            "error", JSONObject().put("message", e.message)).toString())
                    } catch (_: Throwable) {
                    }
                } finally {
                    try {
                        pout.close()
                    } catch (_: Throwable) {
                    }
                }
            }.start()
            val resp = newChunkedResponse(Response.Status.OK, "text/event-stream", pin)
            resp.addHeader("Cache-Control", "no-cache")
            return resp
        }

        private fun writeSse(out: OutputStream, payload: String) {
            out.write("data: $payload\n\n".toByteArray(Charsets.UTF_8))
            out.flush()
        }

        private fun errObj(message: String): JSONObject =
            JSONObject().put("error", JSONObject().put("message", message))

        private fun json(status: Response.Status, obj: JSONObject): Response {
            return newFixedLengthResponse(status, "application/json", obj.toString())
        }
    }
}
