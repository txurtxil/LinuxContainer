package com.example.linux_container

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.*
import java.util.zip.GZIPInputStream

class MainActivity : FlutterActivity() {

    private val NATIVE_PATHS     = "linux_container/native_paths"
    private val FOREGROUND       = "linux_container/foreground"
    private val MEDIAPIPE        = "xtr/mediapipe"
    private val MEDIAPIPE_STREAM = "xtr/mediapipe/stream"
    private val CHANNEL_MAIN     = "xtr/main"

    private val REQUEST_IMPORT = 4711
    private var pendingImport: MethodChannel.Result? = null
    private var mpSink: EventChannel.EventSink? = null

    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // Prefs para saber si el rootfs ya fue extraído
    private val PREFS_NAME       = "xtr_prefs"
    private val PREF_ROOTFS_DONE = "rootfs_extracted"
    private val ROOTFS_ASSET     = "rootfs.tar.gz"

    private val rootfsDir: File get() = File(filesDir, "debian")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ── Canal original: ruta de libs nativas (proot) ─────
        MethodChannel(messenger, NATIVE_PATHS)
            .setMethodCallHandler { call, result ->
                if (call.method == "getNativeLibraryDir") {
                    result.success(applicationContext.applicationInfo.nativeLibraryDir)
                } else {
                    result.notImplemented()
                }
            }

        // ── Canal original: foreground service del agente ────
        MethodChannel(messenger, FOREGROUND)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val i = Intent(this, AgentForegroundService::class.java)
                        i.action = AgentForegroundService.ACTION_START
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
                        else startService(i)
                        result.success(true)
                    }
                    "stop" -> {
                        val i = Intent(this, AgentForegroundService::class.java)
                        i.action = AgentForegroundService.ACTION_STOP
                        startService(i)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Canal original: MediaPipe ─────────────────────────
        MethodChannel(messenger, MEDIAPIPE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> {
                        val path = call.argument<String>("path")
                        val gpu  = call.argument<Boolean>("gpu") ?: true
                        if (path == null) { result.error("ARG", "Falta 'path'", null); return@setMethodCallHandler }
                        Thread {
                            val err = MediaPipeEngine.load(applicationContext, path, gpu)
                            runOnUiThread { if (err == null) result.success(true) else result.error("LOAD", err, null) }
                        }.start()
                    }
                    "generate" -> {
                        val prompt = call.argument<String>("prompt")
                        if (prompt == null) { result.error("ARG", "Falta 'prompt'", null); return@setMethodCallHandler }
                        Thread { runGenerate(prompt, result) }.start()
                    }
                    "unload" -> { MediaPipeEngine.close(); result.success(true) }
                    "importModel" -> {
                        if (pendingImport != null) { result.error("BUSY", "Importación en curso", null); return@setMethodCallHandler }
                        pendingImport = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        try { startActivityForResult(intent, REQUEST_IMPORT) }
                        catch (e: Exception) { pendingImport = null; result.error("PICK", e.message, null) }
                    }
                    "serverStart" -> {
                        val port = call.argument<Int>("port") ?: 8090
                        val path = call.argument<String>("path")
                        val gpu  = call.argument<Boolean>("gpu") ?: true
                        Thread {
                            var err: String? = null
                            if (path != null && !MediaPipeEngine.isLoaded)
                                err = MediaPipeEngine.load(applicationContext, path, gpu)
                            if (err == null && !MediaPipeEngine.isLoaded)
                                err = "El modelo no está cargado."
                            if (err == null) err = MediaPipeServer.start(port)
                            val e = err
                            runOnUiThread { if (e == null) result.success(true) else result.error("SERVER", e, null) }
                        }.start()
                    }
                    "serverStop"   -> { MediaPipeServer.stop(); result.success(true) }
                    "serverStatus" -> result.success(mapOf(
                        "running"     to MediaPipeServer.isRunning,
                        "port"        to MediaPipeServer.port,
                        "modelLoaded" to MediaPipeEngine.isLoaded,
                        "modelPath"   to (MediaPipeEngine.loadedPath ?: "")
                    ))
                    else -> result.notImplemented()
                }
            }

        // ── Canal original: stream de tokens MediaPipe ────────
        EventChannel(messenger, MEDIAPIPE_STREAM)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { mpSink = events }
                override fun onCancel(arguments: Any?) { mpSink = null }
            })

        // ── Canal nuevo: gestión del rootfs bundleado ─────────
        MethodChannel(messenger, CHANNEL_MAIN)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRootfsStatus" -> result.success(mapOf(
                        "extracted" to isRootfsExtracted(),
                        "path"      to rootfsDir.absolutePath
                    ))
                    "extractRootfs"  -> extractRootfsAsync(result)
                    "getRootfsPath"  -> result.success(rootfsDir.absolutePath)
                    "getSystemInfo"  -> result.success(mapOf(
                        "rootfsPath" to rootfsDir.absolutePath,
                        "filesDir"   to filesDir.absolutePath,
                        "extracted"  to isRootfsExtracted(),
                        "nativeLibDir" to applicationContext.applicationInfo.nativeLibraryDir
                    ))
                    // runInProot ya no se usa desde Kotlin — lo hace Dart via native_paths
                    else -> result.notImplemented()
                }
            }
    }

    // ── onCreate: diálogo de primer arranque ──────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // El rootfs lo gestiona ContainerBootstrap.dart (sistema original)
    }

    override fun onDestroy() {
        MediaPipeServer.stop()
        MediaPipeEngine.close()
        mainScope.cancel()
        super.onDestroy()
    }

    // ── Extracción del rootfs ─────────────────────────────────
    private fun extractRootfsAsync(result: MethodChannel.Result?) {
        mainScope.launch {
            try {
                withContext(Dispatchers.IO) { doExtractRootfs() }
                result?.success(mapOf("success" to true, "path" to rootfsDir.absolutePath))
                Toast.makeText(this@MainActivity, "Sistema Debian listo ✓", Toast.LENGTH_LONG).show()
            } catch (e: Exception) {
                Log.e("XTR", "Error extrayendo rootfs", e)
                result?.success(mapOf("success" to false, "error" to e.message))
                Toast.makeText(this@MainActivity, "Error: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun doExtractRootfs() {
        Log.i("XTR", "Extrayendo rootfs desde assets...")
        val assetFiles = assets.list("") ?: emptyArray()
        if (ROOTFS_ASSET !in assetFiles) throw IOException("'$ROOTFS_ASSET' no está en los assets de la APK.")
        if (rootfsDir.exists() && !isRootfsExtracted()) rootfsDir.deleteRecursively()
        rootfsDir.mkdirs()

        // Usar tar del sistema si está disponible (más rápido y robusto)
        val tarBin = listOf("/system/bin/tar", "/system/xbin/tar", "/usr/bin/tar")
            .firstOrNull { File(it).exists() }

        if (tarBin != null) {
            // Extraer el asset a un fichero temporal y luego usar tar
            val tmpFile = File(cacheDir, "rootfs_tmp.tar.gz")
            assets.open(ROOTFS_ASSET).use { inp ->
                FileOutputStream(tmpFile).use { out -> inp.copyTo(out) }
            }
            rootfsDir.mkdirs()
            val proc = ProcessBuilder(tarBin, "xzf", tmpFile.absolutePath, "-C", rootfsDir.absolutePath)
                .redirectErrorStream(true)
                .start()
            val log = proc.inputStream.bufferedReader().readText()
            val exit = proc.waitFor()
            tmpFile.delete()
            if (exit != 0) throw IOException("tar falló (exit $exit): $log")
        } else {
            // Fallback: parser TAR en Kotlin
            assets.open(ROOTFS_ASSET).use { assetStream ->
                GZIPInputStream(BufferedInputStream(assetStream, 65536)).use { gzip ->
                    extractTarKotlin(gzip, rootfsDir)
                }
            }
        }

        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit().putBoolean(PREF_ROOTFS_DONE, true).apply()
        Log.i("XTR", "Rootfs extraído en ${rootfsDir.absolutePath}")
    }

    private fun extractTarKotlin(input: InputStream, destDir: File) {
        val header = ByteArray(512)
        while (true) {
            var n = 0
            while (n < 512) { val r = input.read(header, n, 512 - n); if (r == -1) return; n += r }
            if (header.all { it == 0.toByte() }) return
            val name     = String(header, 0, 100, Charsets.US_ASCII).trimEnd('\u0000')
            val sizeOct  = String(header, 124, 12, Charsets.US_ASCII).trim().trimEnd('\u0000')
            val typeFlag = header[156].toInt().toChar()
            if (name.isEmpty()) continue
            val fileSize = if (sizeOct.isBlank()) 0L else sizeOct.toLong(8)
            val outFile  = File(destDir, name).canonicalFile
            if (!outFile.absolutePath.startsWith(destDir.absolutePath)) { skipBytes(input, fileSize); continue }
            when (typeFlag) {
                '0', '\u0000' -> {
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        val buf = ByteArray(32768); var rem = fileSize
                        while (rem > 0) { val r = input.read(buf, 0, minOf(buf.size.toLong(), rem).toInt()); if (r == -1) break; fos.write(buf, 0, r); rem -= r }
                    }
                    skipBytes(input, (512 - (fileSize % 512)) % 512)
                }
                '2' -> {
                    val target = String(header, 157, 100, Charsets.US_ASCII).trimEnd('\u0000')
                    try { outFile.parentFile?.mkdirs(); Runtime.getRuntime().exec(arrayOf("ln", "-sf", target, outFile.absolutePath)).waitFor() } catch (_: Exception) {}
                    skipBytes(input, fileSize)
                }
                '5' -> { outFile.mkdirs() }
                else -> { skipBytes(input, fileSize); skipBytes(input, (512 - (fileSize % 512)) % 512) }
            }
        }
    }

    private fun skipBytes(input: InputStream, count: Long) {
        var rem = count; val buf = ByteArray(32768)
        while (rem > 0) { val r = input.read(buf, 0, minOf(buf.size.toLong(), rem).toInt()); if (r == -1) break; rem -= r }
    }

    private fun isRootfsExtracted(): Boolean =
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean(PREF_ROOTFS_DONE, false) &&
        rootfsDir.exists() && File(rootfsDir, "bin/bash").exists()

    // ── MediaPipe: generate con streaming ────────────────────
    private fun runGenerate(prompt: String, result: MethodChannel.Result) {
        val sb = StringBuilder()
        val startNs = System.nanoTime()
        var firstNs = 0L
        val err = MediaPipeEngine.generate(prompt) { token, done ->
            if (firstNs == 0L) firstNs = System.nanoTime()
            if (token.isNotEmpty()) sb.append(token)
            runOnUiThread {
                mpSink?.success(mapOf("partial" to token, "done" to done))
                if (done) {
                    val genSecs  = (System.nanoTime() - firstNs) / 1e9
                    val ttftSecs = (firstNs - startNs) / 1e9
                    val toks     = MediaPipeEngine.sizeInTokens(sb.toString())
                    val tps      = if (genSecs > 0) toks / genSecs else 0.0
                    mpSink?.success(mapOf(
                        "stats" to true,
                        "tps"   to tps,
                        "ttft"  to ttftSecs,
                        "toks"  to toks
                    ))
                }
            }
        }
        runOnUiThread { if (err != null) result.error("GEN", err, null) else result.success(sb.toString()) }
    }

    // ── Import modelo .task ───────────────────────────────────
    private fun queryName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (_: Exception) { null }
    }
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_IMPORT) {
            val pending = pendingImport ?: return
            pendingImport = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                pending.error("CANCEL", "Importación cancelada", null)
                return
            }
            val uri = data.data!!
            val name = queryName(uri) ?: "model.task"
            val modelsDir = java.io.File(
                getExternalFilesDir(null), "models"
            ).also { it.mkdirs() }
            val destFile = java.io.File(modelsDir, name)
            try {
                contentResolver.openInputStream(uri)?.use { inp ->
                    destFile.outputStream().use { out -> inp.copyTo(out) }
                }
                pending.success(destFile.absolutePath)
            } catch (e: Exception) {
                pending.error("COPY", e.message, null)
            }
        }
    }

}
