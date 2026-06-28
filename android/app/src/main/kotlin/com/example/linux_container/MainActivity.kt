package com.example.linux_container

import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.*
import java.util.zip.GZIPInputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "XTR"
        private const val CHANNEL_MAIN      = "xtr/main"
        private const val CHANNEL_MEDIAPIPE = "xtr/mediapipe"
        private const val CHANNEL_MP_STREAM = "xtr/mediapipe/stream"

        // Directorio base de datos de la app (no requiere permisos extra)
        // /data/data/com.example.linux_container/files/
        private const val PREFS_NAME       = "xtr_prefs"
        private const val PREF_ROOTFS_DONE = "rootfs_extracted"
        private const val ROOTFS_ASSET     = "rootfs.tar.gz"
    }

    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // Directorio donde se extrae el rootfs
    private val rootfsDir: File get() = File(filesDir, "debian")

    // ── Flutter engine ───────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Canal principal
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MAIN)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // ── Estado del rootfs ────────────────────
                    "getRootfsStatus" -> {
                        result.success(mapOf(
                            "extracted" to isRootfsExtracted(),
                            "path"      to rootfsDir.absolutePath
                        ))
                    }

                    // ── Extraer rootfs (llamado desde Flutter) ─
                    "extractRootfs" -> {
                        extractRootfsAsync(result)
                    }

                    // ── Ejecutar comando en proot ────────────
                    "runInProot" -> {
                        val cmd = call.argument<String>("command") ?: ""
                        runInProot(cmd, result)
                    }

                    // ── Ruta del rootfs ─────────────────────
                    "getRootfsPath" -> {
                        result.success(rootfsDir.absolutePath)
                    }

                    // ── Info del sistema ─────────────────────
                    "getSystemInfo" -> {
                        result.success(mapOf(
                            "rootfsPath"  to rootfsDir.absolutePath,
                            "filesDir"    to filesDir.absolutePath,
                            "extracted"   to isRootfsExtracted()
                        ))
                    }

                    else -> result.notImplemented()
                }
            }

        // Canal MediaPipe (delega a MediaPipeEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIAPIPE)
            .setMethodCallHandler { call, result ->
                MediaPipeEngine.handleMethodCall(this, call, result)
            }
    }

    // ── onCreate: verificar rootfs en primer arranque ────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (!isRootfsExtracted()) {
            // Mostrar diálogo y extraer — Flutter aún no está listo para recibir
            // notificaciones, así que guardamos el estado y Flutter lo consulta
            showFirstRunDialog()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        mainScope.cancel()
    }

    // ── Primer arranque: diálogo + extracción automática ─────
    private fun showFirstRunDialog() {
        Handler(Looper.getMainLooper()).postDelayed({
            AlertDialog.Builder(this)
                .setTitle("XTR Terminal — Primera ejecución")
                .setMessage(
                    "Se va a descomprimir el sistema Debian (~500 MB).\n\n" +
                    "Este proceso tarda 1-3 minutos y sólo ocurre una vez."
                )
                .setCancelable(false)
                .setPositiveButton("Comenzar") { _, _ ->
                    extractRootfsAsync(null)
                }
                .show()
        }, 1500) // esperar a que Flutter cargue la UI
    }

    // ── Extraer rootfs desde assets ──────────────────────────
    private fun extractRootfsAsync(result: MethodChannel.Result?) {
        mainScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    doExtractRootfs()
                }
                result?.success(mapOf("success" to true, "path" to rootfsDir.absolutePath))
                Toast.makeText(
                    this@MainActivity,
                    "Sistema Debian listo ✓",
                    Toast.LENGTH_LONG
                ).show()
            } catch (e: Exception) {
                Log.e(TAG, "Error extrayendo rootfs", e)
                result?.success(mapOf("success" to false, "error" to e.message))
                Toast.makeText(
                    this@MainActivity,
                    "Error al extraer sistema: ${e.message}",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun doExtractRootfs() {
        Log.i(TAG, "Iniciando extracción de rootfs...")

        // Verificar que el asset existe
        val assetFiles = assets.list("") ?: emptyArray()
        if (ROOTFS_ASSET !in assetFiles) {
            throw IOException(
                "Asset '$ROOTFS_ASSET' no encontrado. " +
                "Ejecuta 01_prepare_rootfs.sh en bc-250 primero."
            )
        }

        // Limpiar directorio previo si existe incompleto
        if (rootfsDir.exists() && !isRootfsExtracted()) {
            Log.w(TAG, "Rootfs incompleto encontrado — limpiando...")
            rootfsDir.deleteRecursively()
        }

        rootfsDir.mkdirs()

        // Abrir el .tar.gz desde assets
        assets.open(ROOTFS_ASSET).use { assetStream ->
            GZIPInputStream(BufferedInputStream(assetStream, 65536)).use { gzip ->
                extractTar(gzip, rootfsDir)
            }
        }

        // Marcar como completado
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_ROOTFS_DONE, true)
            .apply()

        Log.i(TAG, "Rootfs extraído correctamente en ${rootfsDir.absolutePath}")
    }

    // ── Parser TAR mínimo (sin dependencias externas) ────────
    private fun extractTar(input: InputStream, destDir: File) {
        val header = ByteArray(512)
        var totalBytes = 0L

        while (true) {
            var bytesRead = 0
            while (bytesRead < 512) {
                val n = input.read(header, bytesRead, 512 - bytesRead)
                if (n == -1) return
                bytesRead += n
            }

            // Fin de archivo TAR: dos bloques de ceros
            if (header.all { it == 0.toByte() }) return

            val name     = header.decodeString(0, 100).trimEnd('\u0000')
            val sizeOct  = header.decodeString(124, 12).trim().trimEnd('\u0000')
            val typeFlag = header[156].toInt().toChar()

            if (name.isEmpty()) continue
            val fileSize = if (sizeOct.isBlank()) 0L else sizeOct.toLong(8)

            val outFile = File(destDir, name).canonicalFile
            if (!outFile.absolutePath.startsWith(destDir.absolutePath)) {
                // Path traversal — skip
                skipBytes(input, fileSize)
                continue
            }

            when (typeFlag) {
                '0', '\u0000' -> {
                    // Fichero regular
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        val buf = ByteArray(32768)
                        var remaining = fileSize
                        while (remaining > 0) {
                            val toRead = minOf(buf.size.toLong(), remaining).toInt()
                            val n = input.read(buf, 0, toRead)
                            if (n == -1) break
                            fos.write(buf, 0, n)
                            remaining -= n
                            totalBytes += n
                        }
                    }
                    // Alinear al siguiente bloque de 512
                    val padding = (512 - (fileSize % 512)) % 512
                    skipBytes(input, padding)
                }
                '2' -> {
                    // Enlace simbólico
                    val linkTarget = header.decodeString(157, 100).trimEnd('\u0000')
                    try {
                        outFile.parentFile?.mkdirs()
                        Runtime.getRuntime().exec(
                            arrayOf("ln", "-sf", linkTarget, outFile.absolutePath)
                        ).waitFor()
                    } catch (_: Exception) {}
                    skipBytes(input, fileSize)
                }
                '5' -> {
                    // Directorio
                    outFile.mkdirs()
                    skipBytes(input, fileSize)
                }
                else -> {
                    skipBytes(input, fileSize)
                    val padding = (512 - (fileSize % 512)) % 512
                    skipBytes(input, padding)
                }
            }

            if (totalBytes > 0 && totalBytes % (50 * 1024 * 1024) == 0L) {
                Log.i(TAG, "Extrayendo... ${totalBytes / (1024 * 1024)} MB")
            }
        }
    }

    private fun skipBytes(input: InputStream, count: Long) {
        var remaining = count
        val buf = ByteArray(32768)
        while (remaining > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
            if (n == -1) break
            remaining -= n
        }
    }

    private fun ByteArray.decodeString(offset: Int, length: Int): String {
        return String(this, offset, length, Charsets.US_ASCII)
    }

    // ── Verificar si el rootfs está extraído ─────────────────
    private fun isRootfsExtracted(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        return prefs.getBoolean(PREF_ROOTFS_DONE, false) &&
               rootfsDir.exists() &&
               File(rootfsDir, "bin/bash").exists()
    }

    // ── Ejecutar comando dentro de proot ─────────────────────
    private fun runInProot(command: String, result: MethodChannel.Result) {
        mainScope.launch {
            try {
                val output = withContext(Dispatchers.IO) {
                    executeProot(command)
                }
                result.success(output)
            } catch (e: Exception) {
                result.error("PROOT_ERROR", e.message, null)
            }
        }
    }

    private fun executeProot(command: String): String {
        val prootBin = File(filesDir, "usr/bin/proot")
        val rootPath = rootfsDir.absolutePath

        // Usar proot si está disponible, sino intentar con el del sistema
        val prootCmd = if (prootBin.exists()) prootBin.absolutePath else "proot"

        val fullCmd = arrayOf(
            prootCmd,
            "--rootfs=$rootPath",
            "--bind=/proc",
            "--bind=/dev",
            "--bind=/sys",
            "--pwd=/root",
            "/bin/bash", "-c", command
        )

        val process = Runtime.getRuntime().exec(fullCmd)
        val stdout  = process.inputStream.bufferedReader().readText()
        val stderr  = process.errorStream.bufferedReader().readText()
        process.waitFor()

        return if (stderr.isNotBlank() && stdout.isBlank()) stderr else stdout
    }
}
