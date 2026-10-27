package dev.voicechat.voicechat_probe

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class ClipboardFiles(private val context: Context) {
    private data class Transfer(val file: File, val output: FileOutputStream, val size: Long, var written: Long = 0)
    private val transfers = mutableMapOf<String, Transfer>()
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "begin" -> {
                    require(transfers.size < 64)
                    val name = call.argument<String>("name") ?: error("name")
                    val size = call.argument<Number>("size")?.toLong() ?: 0
                    require(name.length <= 1024 && size in 1..314572800 && transfers.values.sumOf { it.size } + size <= 314572800)
                    val root = File(context.cacheDir, "VoiceChatClipboard").apply { mkdirs() }
                    root.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 86400000 }?.forEach { it.deleteRecursively() }
                    val filename = name.replace('\\', '/').substringAfterLast('/')
                    require(filename.isNotBlank() && filename != "." && filename != "..")
                    val id = UUID.randomUUID().toString()
                    val directory = File(root, id).apply { check(mkdir()) }
                    val file = File(directory, filename)
                    transfers[id] = Transfer(file, FileOutputStream(file), size)
                    result.success(id)
                }
                "write" -> {
                    val transfer = transfers[call.argument<String>("id")] ?: error("transfer")
                    val bytes = call.argument<ByteArray>("bytes") ?: error("bytes")
                    require(bytes.size <= 4 * 1024 * 1024 && transfer.written + bytes.size <= transfer.size)
                    transfer.output.write(bytes)
                    transfer.written += bytes.size
                    result.success(null)
                }
                "commit", "cancel" -> {
                    val ids = call.argument<List<String>>("ids") ?: error("ids")
                    require(ids.isNotEmpty() && ids.size <= 64 && ids.toSet().size == ids.size)
                    if (call.method == "commit") {
                        val files = ids.map { id ->
                            val transfer = transfers[id] ?: error("transfer")
                            check(transfer.written == transfer.size)
                            transfer.output.fd.sync()
                            FileProvider.getUriForFile(context, context.packageName + ".clipboard", transfer.file)
                        }
                        val clip = ClipData.newUri(context.contentResolver, "VoiceChat", files.first())
                        files.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                        (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                    }
                    ids.forEach { id -> transfers.remove(id)?.let {
                        it.output.close()
                        if (call.method == "cancel") it.file.parentFile?.deleteRecursively()
                    } }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("clipboard", "Не удалось скопировать файл.", null) }
    }
}
