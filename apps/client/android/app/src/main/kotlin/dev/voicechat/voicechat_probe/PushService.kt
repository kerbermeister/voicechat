package dev.voicechat.voicechat_probe

import android.app.Notification
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.media.AudioAttributes
import android.media.RingtoneManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import androidx.work.*
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Native receiver works without a Flutter engine or access to E2EE keys. */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        getSharedPreferences("voicechat_push", MODE_PRIVATE).edit().putString("fcmToken", token).apply()
        PushWork.enqueue(this, "rotate", token)
        AppNotifications.tokenChanged()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val binding = message.data["binding"] ?: return
        val notice = message.data["notice"] ?: return
        if (binding != PushNotifications.binding(this) || notice.length > 128) return
        PushWork.enqueue(this, "receive", notice, binding)
    }
}

object PushNotifications {
    private const val STORE = "voicechat_push"
    private const val PREFIX = "vc-push:"

    fun configure(context: Context, account: String, base: String, binding: String) {
        require(URL(base).protocol == "https" && URL(base).userInfo == null)
        val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        if (prefs.getString("binding", null) != binding) clear(context)
        prefs.edit().putString("account", account).putString("base", base.trimEnd('/'))
            .putString("binding", binding).commit()
        FirebaseMessaging.getInstance().isAutoInitEnabled = true
    }

    fun clear(context: Context) {
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit().clear().commit()
        FirebaseMessaging.getInstance().isAutoInitEnabled = false
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 23) manager.activeNotifications
            .filter { it.tag?.startsWith(PREFIX) == true }.forEach { manager.cancel(it.tag, it.id) }
    }

    fun account(context: Context) = context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString("account", null)
    fun binding(context: Context) = context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString("binding", null)

    fun request(context: Context, binding: String, path: String, body: JSONObject): JSONObject? {
        val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        if (binding != prefs.getString("binding", null)) return null
        val base = prefs.getString("base", null) ?: return null
        val connection = URL("$base/push/android/$path").openConnection() as HttpsURLConnection
        connection.connectTimeout = 3000
        connection.readTimeout = 3000
        connection.instanceFollowRedirects = false
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Authorization", "Bearer $binding")
        connection.setRequestProperty("Content-Type", "application/json")
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            if (connection.responseCode == 429 || connection.responseCode >= 500) throw IOException("Push endpoint unavailable")
            if (connection.responseCode != 200) return null
            val output = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(1024)
                while (true) {
                    val size = input.read(buffer)
                    if (size < 0) break
                    if (output.size() + size > 8192) throw IOException("Push response too large")
                    output.write(buffer, 0, size)
                }
            }
            val raw = output.toByteArray()
            if (binding != prefs.getString("binding", null)) return null
            return JSONObject(String(raw, Charsets.UTF_8))
        } finally { connection.disconnect() }
    }

    fun resolve(context: Context, binding: String, notice: String) =
        request(context, binding, "resolve", JSONObject().put("notice", notice))

    fun receive(context: Context, binding: String?, notice: String?) {
        if (binding == null || notice == null || notice.length > 128) return
        try {
            val data = resolve(context, binding, notice) ?: return
            val manager = context.getSystemService(NotificationManager::class.java)
            val isCall = data.optString("kind") == "call"
            val video = isCall && data.optBoolean("video")
            val tag = PREFIX + if (data.has("session")) data.getString("session") else data.getString("room")
            if (data.optString("kind") == "dismiss") {
                manager.cancel(tag, 0)
                IncomingCallActivity.dismiss(data.optString("call", notice))
                return
            }
            if (AppUpdater.foreground) return
            val routeNotice = data.optString("call", notice)
            if (isCall) manager.cancel(PREFIX + data.getString("room"), 0)
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                NotificationChannel("messages", "Новые сообщения", NotificationManager.IMPORTANCE_DEFAULT))
            if (isCall && Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel("push_calls", "Входящие звонки в фоне", NotificationManager.IMPORTANCE_HIGH)
                channel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
                channel.enableVibration(true)
                manager.createNotificationChannel(channel)
            }
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .setAction(PREFIX + routeNotice).putExtra("pushBinding", binding).putExtra("pushNotice", routeNotice)
                .putExtra("pushTag", tag)
                .putExtra("pushExpires", data.getLong("expires"))
            val open = PendingIntent.getActivity(context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, if (isCall) "push_calls" else "messages")
                else Notification.Builder(context).setDefaults(Notification.DEFAULT_SOUND)
            builder.setSmallIcon(android.R.drawable.sym_action_chat).setContentTitle("VoiceChat")
                .setContentText(if (video) "Входящий видеозвонок" else if (isCall) "Входящий звонок" else "Новое сообщение")
                .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true)
                .setOnlyAlertOnce(true).setCategory(if (isCall) Notification.CATEGORY_CALL else Notification.CATEGORY_MESSAGE).setContentIntent(open)
            if (isCall) {
                val remaining = (data.getLong("expires") * 1000 - System.currentTimeMillis()).coerceAtMost(45000L)
                if (remaining <= 0) return
                val incoming = Intent(intent).setClass(context, IncomingCallActivity::class.java)
                val fullScreen = PendingIntent.getActivity(context, 0, incoming,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val answer = PendingIntent.getActivity(context, 0, Intent(incoming)
                    .setAction(PREFIX + routeNotice + ":answer").putExtra("pushAction", "answer"),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val decline = PendingIntent.getBroadcast(context, 0, Intent(context, PushDeclineReceiver::class.java)
                    .setAction(PREFIX + routeNotice + ":decline").putExtra("pushBinding", binding)
                    .putExtra("pushNotice", routeNotice).putExtra("pushTag", tag),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                if (Build.VERSION.SDK_INT >= 31) builder.setStyle(Notification.CallStyle.forIncomingCall(
                    Person.Builder().setName("VoiceChat").setImportant(true).build(), decline, answer).setIsVideo(video))
                else builder.addAction(android.R.drawable.sym_action_call, if (video) "Ответить с камерой" else "Ответить", answer)
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Отклонить", decline)
                    .setPriority(Notification.PRIORITY_MAX)
                if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(remaining)
                else {
                    // Android7 has no Notification timeout. Use a system alarm so
                    // expiry survives the receiver process being reclaimed.
                    val timeout = PendingIntent.getBroadcast(context, 0,
                        Intent(context, PushDeclineReceiver::class.java).setAction(PREFIX + routeNotice + ":timeout")
                            .putExtra("pushBinding", binding).putExtra("pushNotice", routeNotice)
                            .putExtra("pushTag", tag).putExtra("pushTimeout", true),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    context.getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + remaining, timeout)
                }
                if (Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent()) builder.setFullScreenIntent(fullScreen, true)
                builder.setOngoing(true)
            }
            if (binding != binding(context)) return
            val notification = builder.build()
            if (isCall) notification.flags = notification.flags or Notification.FLAG_INSISTENT
            manager.notify(tag, 0, notification)
        } catch (error: IOException) {
            throw error
        } catch (_: Exception) {
            // No token, event or server response is written to logs.
        }
    }

    fun decline(context: Context, binding: String, notice: String) {
        request(context, binding, "action", JSONObject().put("notice", notice).put("action", "decline"))
    }
}

class PushDeclineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val binding = intent.getStringExtra("pushBinding") ?: return
        if (binding != PushNotifications.binding(context)) return
        val notice = intent.getStringExtra("pushNotice") ?: return
        context.getSystemService(NotificationManager::class.java).cancel(intent.getStringExtra("pushTag"), 0)
        if (intent.getBooleanExtra("pushTimeout", false)) return
        PushWork.enqueue(context, "decline", notice, binding)
    }
}

object PushWork {
    fun enqueue(context: Context, action: String, value: String, binding: String? = PushNotifications.binding(context)) {
        if (binding == null) return
        val request = OneTimeWorkRequest.Builder(PushWorker::class.java)
            .setInputData(Data.Builder().putString("action", action).putString("value", value).putString("binding", binding).build())
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, 10, TimeUnit.SECONDS)
        if (Build.VERSION.SDK_INT >= 31) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        val id = MessageDigest.getInstance("SHA-256").digest("$binding:$action:$value".toByteArray())
            .joinToString("") { "%02x".format(it) }
        WorkManager.getInstance(context).enqueueUniqueWork("vc-push:$id", ExistingWorkPolicy.KEEP, request.build())
    }
}

class PushWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val binding = inputData.getString("binding") ?: return Result.success()
        if (binding != PushNotifications.binding(applicationContext)) return Result.success()
        val value = inputData.getString("value") ?: return Result.success()
        return try {
            when (inputData.getString("action")) {
                "rotate" -> PushNotifications.request(applicationContext, binding, "rotate", JSONObject().put("token", value))
                "decline" -> PushNotifications.decline(applicationContext, binding, value)
                else -> PushNotifications.receive(applicationContext, binding, value)
            }
            Result.success()
        } catch (_: IOException) {
            if (runAttemptCount < 5) Result.retry() else Result.failure()
        }
    }
}
