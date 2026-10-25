package dev.voicechat.voicechat_probe

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngineCache
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** Only this package's private APK is ever accepted. No external install intents. */
class AppUpdater(private val activity: Activity) {
    companion object {
        private val worker = Executors.newSingleThreadExecutor()
        @Volatile var foreground = false
        @Volatile var preparing = false
        private var cacheCleaned = false
        fun prefs(context: Context) = context.getSharedPreferences("app-update", Context.MODE_PRIVATE)
        fun cache(context: Context) = File(context.cacheDir, "app-update")
        fun cachedFile(context: Context, name: String): File {
            check(Regex("[a-f0-9-]{36}\\.apk").matches(name)) { "Неверный временный APK." }
            val file = File(cache(context), name)
            check(file.canonicalFile.parentFile == cache(context).canonicalFile) { "Неверный путь APK." }
            return file
        }
        @Suppress("DEPRECATION")
        fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        @Suppress("DEPRECATION")
        fun flags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        @Suppress("DEPRECATION")
        fun signers(info: PackageInfo): Set<String> {
            val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
            return signatures?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }?.toSet() ?: emptySet()
        }
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
        fun clear(context: Context, message: String) {
            val name = prefs(context).getString("file", null)
            prefs(context).edit().clear().putString("status", message).commit()
            if (name != null) cachedFile(context, name).delete()
            Handler(Looper.getMainLooper()).post {
                FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)?.let {
                    MethodChannel(it.dartExecutor.binaryMessenger, "voicechat/update").invokeMethod("stateChanged", null)
                }
            }
        }
    }

    init {
        synchronized(worker) {
            if (!cacheCleaned) {
                val pendingFile = prefs(activity).getString("file", null)
                cache(activity).listFiles()?.filter {
                    it.name != pendingFile && Regex("[a-f0-9-]{36}\\.apk").matches(it.name)
                }?.forEach { it.delete() }
                cacheCleaned = true
            }
        }
    }

    private val manager get() = activity.packageManager
    private val installer get() = manager.packageInstaller
    private val preferences get() = prefs(activity)
    private fun installed() = manager.getPackageInfo(activity.packageName, flags())
    private fun selected(args: Map<*, *>): File {
        val path = args["path"] as? String ?: error("Нет пути APK.")
        val file = cachedFile(activity, File(path).name)
        check(file.canonicalPath == path) { "APK вне приватного кеша." }
        return file
    }
    private fun allowed() = Build.VERSION.SDK_INT < 26 || manager.canRequestPackageInstalls()

    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> {
                    val info = installed()
                    val expected = preferences.getLong("version", 0)
                    val id = preferences.getInt("session", -1)
                    val session = if (id >= 0) installer.getSessionInfo(id) else null
                    if (expected > 0 && code(info) >= expected) clear(activity, "Обновление установлено.")
                    else if (id >= 0 && !preparing && (session == null || !session.isSealed)) {
                        if (session != null) installer.abandonSession(id)
                        clear(activity, "Установка не завершена. Можно проверить обновления снова.")
                    }
                    result.success(mapOf("applicationId" to info.packageName, "versionName" to info.versionName,
                        "versionCode" to code(info), "sdk" to Build.VERSION.SDK_INT,
                        "pending" to (preferences.getInt("session", -1) >= 0),
                        "status" to preferences.getString("status", "")))
                }
                "allowed" -> result.success(allowed())
                "settings" -> {
                    if (Build.VERSION.SDK_INT >= 26) activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "prepare" -> {
                    check(!preparing && preferences.getInt("session", -1) < 0) { "Установка уже выполняется." }
                    val directory = cache(activity)
                    directory.mkdirs()
                    directory.listFiles()?.filter { it.isFile && it.lastModified() < System.currentTimeMillis() - 86400000 }
                        ?.forEach { it.delete() }
                    val file = cachedFile(activity, UUID.randomUUID().toString()+".apk")
                    check(!file.exists() || file.delete()) { "Не удалось очистить временный APK." }
                    result.success(file.canonicalPath)
                }
                "discard" -> {
                    val args = call.arguments as? Map<*, *> ?: error("Нет пути APK.")
                    val file = selected(args)
                    if (!preparing && preferences.getString("file", null) != file.name) file.delete()
                    result.success(null)
                }
                "verify", "install" -> {
                    check(!preparing) { "Проверка APK уже выполняется." }
                    val args = call.arguments as? Map<*, *> ?: error("Нет описания APK.")
                    preparing = true
                    worker.execute {
                        try {
                            verify(args)
                            if (call.method == "install") install(args)
                            activity.runOnUiThread { result.success(null) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("update", error.message ?: "Android отклонил APK.", null) }
                        } finally { preparing = false }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("update", error.message, null) }
    }

    private fun verify(args: Map<*, *>) {
        val file = selected(args)
        val size = (args["sizeBytes"] as? Number)?.toLong() ?: 0
        check(size in 1..(300L * 1024 * 1024) && file.length() == size) { "Неверный размер APK." }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        check(hex(digest.digest()) == args["sha256"]) { "Проверка целостности APK не пройдена." }
        val archive = manager.getPackageArchiveInfo(file.path, flags()) ?: error("APK повреждён.")
        val current = installed()
        check(archive.packageName == activity.packageName && args["applicationId"] == activity.packageName) { "APK другого приложения." }
        check(code(archive) == (args["versionCode"] as? Number)?.toLong() && code(archive) > code(current)
            && archive.versionName == args["versionName"]) { "Версия APK не совпадает с выбранным обновлением." }
        check(archive.applicationInfo!!.minSdkVersion == (args["minSdk"] as? Number)?.toInt()
            && archive.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT) { "APK несовместим с этим Android." }
        check(signers(current).isNotEmpty() && signers(archive) == signers(current)) { "Подпись APK отличается. Текущее приложение и данные сохранены." }
    }

    private fun install(args: Map<*, *>) {
        check(foreground && !activity.isFinishing && !activity.isDestroyed) { "Вернитесь в приложение и повторите установку." }
        check(!CallService.running && !ScreenService.running && !MainActivity.hasPendingSave()) { "Сначала завершите звонок и демонстрацию экрана." }
        check(allowed()) { "Разрешите установку в настройках Android." }
        check(preferences.getInt("session", -1) < 0) { "Установка уже выполняется." }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(activity.packageName)
            setSize(selected(args).length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(params)
        var committed = false
        try {
            check(preferences.edit().putInt("session", id)
                .putLong("version", (args["versionCode"] as Number).toLong())
                .putString("file", selected(args).name).commit())
            installer.openSession(id).use { session ->
                // Hash the very bytes written to the session, preventing a check/copy race.
                val digest = MessageDigest.getInstance("SHA-256")
                var size = 0L
                session.openWrite("base.apk", 0, selected(args).length()).use { output ->
                    selected(args).inputStream().use { input ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = input.read(buffer); if (count < 0) break
                            size += count
                            check(size <= (args["sizeBytes"] as Number).toLong()) { "APK изменился во время установки." }
                            digest.update(buffer, 0, count); output.write(buffer, 0, count)
                        }
                    }
                    session.fsync(output)
                }
                check(size == (args["sizeBytes"] as Number).toLong() && hex(digest.digest()) == args["sha256"]) { "APK изменился во время установки." }
                check(code(installed()) < (args["versionCode"] as Number).toLong() && foreground
                    && !CallService.running && !ScreenService.running && !MainActivity.hasPendingSave()) { "Состояние приложения изменилось. Повторите установку." }
                val token = UUID.randomUUID().toString()
                check(preferences.edit().putInt("session", id).putLong("version", (args["versionCode"] as Number).toLong())
                    .putString("file", selected(args).name).putString("token", token).putString("status", "Ожидается подтверждение Android.").commit())
                val intent = Intent(activity, UpdateResultReceiver::class.java).apply {
                    action = "${activity.packageName}.UPDATE_RESULT"
                    data = Uri.parse("voicechat-update://result/$token")
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val sender = PendingIntent.getBroadcast(activity, id, intent, flags).intentSender
                session.commit(sender)
                committed = true
            }
        } finally {
            if (!committed) { installer.abandonSession(id); clear(activity, "Установка не началась. Повторите попытку.") }
        }
    }
}

class UpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = AppUpdater.prefs(context)
        val id = prefs.getInt("session", -1)
        val token = prefs.getString("token", null) ?: return
        if (id < 0 || intent.action != "${context.packageName}.UPDATE_RESULT" ||
            intent.data?.toString() != "voicechat-update://result/$token" ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != id) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                if (!AppUpdater.foreground) {
                    context.packageManager.packageInstaller.abandonSession(id)
                    AppUpdater.clear(context, "Установка приостановлена. Повторите её из приложения.")
                    return
                }
                @Suppress("DEPRECATION")
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                try {
                    requireNotNull(confirmation)
                    context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {
                    context.packageManager.packageInstaller.abandonSession(id)
                    AppUpdater.clear(context, "Не удалось открыть установщик Android.")
                }
            }
            PackageInstaller.STATUS_SUCCESS -> AppUpdater.clear(context, "Обновление установлено.")
            else -> AppUpdater.clear(context, when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
                PackageInstaller.STATUS_FAILURE_ABORTED -> "Установка отменена. Текущая версия сохранена."
                PackageInstaller.STATUS_FAILURE_STORAGE -> "Недостаточно места для установки. Освободите место и повторите."
                PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android запретил установку. Проверьте разрешения устройства."
                else -> "Android отклонил APK. Текущая версия и данные сохранены."
            })
        }
    }
}
