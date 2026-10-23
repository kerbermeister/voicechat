package dev.voicechat.voicechat_probe

import android.content.Intent
import android.content.Context
import android.os.Build
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    // The call engine can outlive its window; selected media handles must outlive it too.
    companion object {
        const val ENGINE_ID = "voicechat-call-engine"
        private var imageResult: MethodChannel.Result? = null
        private val imageRequest = 7501
        private var maxImageCount = 24
        private var selectedImages = emptySet<String>()
        private var fileResult: MethodChannel.Result? = null
        private var maxFileCount = 5
        private val selectedFiles = mutableSetOf<String>()
        private var saveResult: MethodChannel.Result? = null
        private val saves = mutableMapOf<String, Pair<Uri, OutputStream>>()

    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)
    override fun shouldDestroyEngineWithHost(): Boolean = !CallService.running && !ScreenService.running

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        val first = FlutterEngineCache.getInstance().get(ENGINE_ID) == null
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
        if (first) {
            flutterEngine.platformViewsController.registry.registerViewFactory("voicechat/youtube", YouTubeFactory())
            val app = applicationContext
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/screen").setMethodCallHandler { call, result ->
                val service = Intent(app, ScreenService::class.java)
                when (call.method) {
                    "start" -> {
                        if (ScreenService.pending != null) {
                            result.error("busy", "Screen service is starting", null)
                        } else {
                            ScreenService.pending = result
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) app.startForegroundService(service) else app.startService(service)
                            } catch (_: Exception) {
                                ScreenService.pending = null
                                result.error("projection_service", "Cannot start screen service", null)
                            }
                        }
                    }
                    "stop" -> { app.stopService(service); result.success(null) }
                    else -> result.notImplemented()
                }
            }
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/calls").setMethodCallHandler { call, result ->
                val active = call.arguments as? Boolean
                if (call.method != "active" || active == null) { result.error("invalid", "Invalid call state", null); return@setMethodCallHandler }
                try {
                    val service = Intent(app, CallService::class.java)
                    if (active) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) app.startForegroundService(service) else app.startService(service)
                    } else app.stopService(service)
                    result.success(null)
                } catch (_: Exception) { result.error("background", "Cannot maintain the call in background", null) }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/links")
            .setMethodCallHandler { call, result ->
                val uri = (call.arguments as? String)?.let(Uri::parse)
                if (call.method != "open" || uri == null || uri.scheme !in listOf("http", "https") || uri.host.isNullOrEmpty() || uri.userInfo != null) {
                    result.error("invalid", "Invalid link", null)
                } else try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                    result.success(null)
                } catch (_: Exception) { result.error("open", "Cannot open browser", null) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/save")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDirectory" -> result.success(cacheDir.canonicalPath)
                    "begin" -> {
                        if (saveResult != null) { result.error("busy", "Save picker is open", null); return@setMethodCallHandler }
                        saveResult = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                type = call.argument<String>("mime") ?: "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")?.replace('/', '_')?.replace('\\', '_'))
                                addCategory(Intent.CATEGORY_OPENABLE)
                            }, 7503)
                        } catch (_: Exception) { saveResult = null; result.error("save", "Cannot open save picker", null) }
                    }
                    "write" -> {
                        val output = saves[call.argument<String>("id")]?.second
                        val bytes = call.argument<ByteArray>("bytes")
                        if (output == null || bytes == null || bytes.size > 4 * 1024 * 1024) { result.error("invalid", "Invalid save", null); return@setMethodCallHandler }
                        Thread {
                            try { output.write(bytes); runOnUiThread { result.success(null) } }
                            catch (_: Exception) { runOnUiThread { result.error("save", "Cannot write file", null) } }
                        }.start()
                    }
                    "finish" -> {
                        val save = saves.remove(call.argument<String>("id"))
                        try {
                            save?.second?.close()
                            if (save != null && call.argument<Boolean>("success") != true) android.provider.DocumentsContract.deleteDocument(contentResolver, save.first)
                            result.success(null)
                        } catch (_: Exception) { result.error("save", "Cannot finish file", null) }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/files")
            .setMethodCallHandler { call, result ->
                val value = call.argument<String>("uri")
                when (call.method) {
                    "choose" -> {
                        if (fileResult != null) { result.error("busy", "Picker is open", null); return@setMethodCallHandler }
                        maxFileCount = call.argument<Int>("max_count") ?: 5
                        if (maxFileCount !in 1..20) { result.error("invalid", "Invalid file count", null); return@setMethodCallHandler }
                        fileResult = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_GET_CONTENT).apply {
                                type = if (call.argument<Boolean>("video") == true) "video/*" else "*/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                                addCategory(Intent.CATEGORY_OPENABLE)
                            }, 7502)
                        } catch (_: Exception) { fileResult = null; result.error("picker", "Cannot open files", null) }
                    }
                    "release" -> { selectedFiles.remove(value); result.success(null) }
                    "read" -> {
                        val start = call.argument<Int>("start") ?: -1
                        val end = call.argument<Int>("end") ?: -1
                        if (value !in selectedFiles || start < 0 || end <= start || end - start > 4 * 1024 * 1024 || end > 300 * 1024 * 1024) {
                            result.error("invalid", "Invalid file range", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val bytes = contentResolver.openInputStream(Uri.parse(value))!!.use { input ->
                                    var skipped = 0L
                                    while (skipped < start) {
                                        val n = input.skip(start - skipped)
                                        if (n == 0L) { require(input.read() >= 0); skipped++ } else skipped += n
                                    }
                                    val output = ByteArray(end - start)
                                    var offset = 0
                                    while (offset < output.size) {
                                        val n = input.read(output, offset, output.size - offset)
                                        require(n > 0) { "Unexpected end of file" }; offset += n
                                    }
                                    output
                                }
                                runOnUiThread { result.success(bytes) }
                            } catch (_: Exception) { runOnUiThread { result.error("read", "Cannot read file", null) } }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/images")
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    val uri = call.argument<String>("uri")
                    val limit = call.argument<Int>("max_bytes")
                    if (uri == null || uri !in selectedImages || limit == null || limit !in 1..(10 * 1024 * 1024)) {
                        result.error("invalid", "Invalid image request", null)
                    } else readImage(uri, limit, result)
                    return@setMethodCallHandler
                }
                if (call.method != "choose") { result.notImplemented(); return@setMethodCallHandler }
                maxImageCount = call.argument<Int>("max_count") ?: 24
                if (maxImageCount !in 1..64) { result.error("invalid", "Invalid image count", null); return@setMethodCallHandler }
                if (imageResult != null) { result.error("busy", "Picker is already open", null); return@setMethodCallHandler }
                imageResult = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_GET_CONTENT).apply {
                        type = "image/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        addCategory(Intent.CATEGORY_OPENABLE)
                    }, imageRequest)
                } catch (error: Exception) {
                    imageResult = null
                    result.error("unavailable", "Cannot open image picker", null)
                }
            }
    }

    override fun onDestroy() {
        imageResult?.success(null); imageResult = null
        fileResult?.success(null); fileResult = null
        saveResult?.success(null); saveResult = null
        if (!CallService.running && !ScreenService.running) {
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            selectedImages = emptySet()
            selectedFiles.clear()
            for ((uri, output) in saves.values) {
                try { output.close(); android.provider.DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
            }
            saves.clear()
        }
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 7503) {
            val result = saveResult ?: return
            saveResult = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) { result.success(null); return }
            try {
                val output = contentResolver.openOutputStream(uri, "wt") ?: error("Output unavailable")
                val id = UUID.randomUUID().toString()
                saves[id] = Pair(uri, output)
                result.success(id)
            } catch (_: Exception) { result.error("save", "Cannot create file", null) }
            return
        }
        if (requestCode == 7502) {
            val result = fileResult ?: return
            fileResult = null
            if (resultCode != RESULT_OK || data == null) { result.success(null); return }
            try {
                val uris = data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } } ?: listOfNotNull(data.data)
                require(uris.size in 1..maxFileCount && uris.all { it.scheme == "content" })
                val files = uris.map { uri ->
                    var name = "file"
                    var size = -1L
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) { name = cursor.getString(0) ?: name; size = cursor.getLong(1) }
                    }
                    require(size in 1..(300L * 1024 * 1024))
                    mapOf("uri" to uri.toString(), "name" to name, "size" to size, "mime" to (contentResolver.getType(uri) ?: "application/octet-stream"))
                }
                selectedFiles.addAll(uris.map { it.toString() })
                result.success(files)
            } catch (_: Exception) { result.error("invalid", "Invalid file count, unavailable file or larger than 300 MB", null) }
            return
        }
        if (requestCode != imageRequest) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = imageResult ?: return
        imageResult = null
        if (resultCode != RESULT_OK || data == null) { result.success(null); return }
        val uris = data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
            ?: listOfNotNull(data.data)
        if (uris.size > maxImageCount || uris.any { it.scheme != "content" }) {
            result.error("invalid", "Too many images or unsupported provider", null)
            return
        }
        selectedImages = uris.map { it.toString() }.toSet()
        result.success(uris.map { it.toString() })
    }

    private fun readImage(value: String, maxImageBytes: Int, result: MethodChannel.Result) {
        val uri = Uri.parse(value)
        Thread {
            try {
                var name = "image"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                }
                // Read the provider URI directly; never cache an unencrypted image in app storage.
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= maxImageBytes) { "Image exceeds 10 MB" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: error("Image unavailable")
                selectedImages = selectedImages - value
                require(bytes.isNotEmpty()) { "Image is empty" }
                runOnUiThread { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (error: Exception) {
                runOnUiThread { result.error("image_unavailable", "Cannot read image (maximum 10 MB)", null) }
            }
        }.start()
    }
}
