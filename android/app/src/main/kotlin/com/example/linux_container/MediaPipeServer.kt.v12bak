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
            s.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
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
        MediaPipeEngine.loadedPath?.substringAfterLast('/') ?: "mediapipe-local"

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

            if (!MediaPipeEngine.isLoaded) {
                return json(Response.Status.INTERNAL_ERROR,
                    errObj("El modelo no está cargado en el motor."))
            }
            return if (stream) streamChat(prompt, temperature, topK, topP)
            else blockingChat(prompt, temperature, topK, topP)
        }

        /** Convierte los mensajes OpenAI a la plantilla de turnos de Gemma. */
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
            val (err, text) = MediaPipeEngine.generateBlocking(prompt, temp, topK, topP)
            if (err != null) return json(Response.Status.INTERNAL_ERROR, errObj(err))
            val msg = JSONObject().put("role", "assistant").put("content", text)
            val choice = JSONObject().put("index", 0).put("message", msg)
                .put("finish_reason", "stop")
            val pt = MediaPipeEngine.sizeInTokens(prompt)
            val ct = MediaPipeEngine.sizeInTokens(text)
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
                    val err = MediaPipeEngine.generate(prompt, temp, topK, topP) { token, done ->
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
