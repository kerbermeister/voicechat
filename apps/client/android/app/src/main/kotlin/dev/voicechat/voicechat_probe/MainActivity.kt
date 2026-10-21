package dev.voicechat.voicechat_probe

import android.content.Intent
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var imageResult: MethodChannel.Result? = null
    private val imageRequest = 7501
    private val maxImageBytes = 10 * 1024 * 1024

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voicechat/images")
            .setMethodCallHandler { call, result ->
                if (call.method != "choose") { result.notImplemented(); return@setMethodCallHandler }
                if (imageResult != null) { result.error("busy", "Picker is already open", null); return@setMethodCallHandler }
                imageResult = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_GET_CONTENT).apply {
                        type = "image/*"
                        addCategory(Intent.CATEGORY_OPENABLE)
                    }, imageRequest)
                } catch (error: Exception) {
                    imageResult = null
                    result.error("unavailable", "Cannot open image picker", null)
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != imageRequest) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = imageResult ?: return
        imageResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { result.success(null); return }
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
                require(bytes.isNotEmpty()) { "Image is empty" }
                runOnUiThread { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (error: Exception) {
                runOnUiThread { result.error("image_unavailable", "Cannot read image (maximum 10 MB)", null) }
            }
        }.start()
    }
}
