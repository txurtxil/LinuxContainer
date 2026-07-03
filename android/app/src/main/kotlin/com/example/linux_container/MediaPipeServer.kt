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
