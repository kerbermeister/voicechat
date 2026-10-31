package dev.voicechat.voicechat_probe

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Notifications from the running Matrix sync; this does not replace push. */
object AppNotifications {
    const val PERMISSION_REQUEST = 7510
    private const val PREFIX = "vc-event:"
    private var activity = WeakReference<MainActivity>(null)
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var session: String? = null
    private var enabled = false
    private var pending: Pair<String, MethodChannel.Result>? = null
    private val manager get() = context.getSystemService(NotificationManager::class.java)

    fun attach(host: MainActivity, messenger: BinaryMessenger) {
        context = host.applicationContext
        activity = WeakReference(host)
        channel = MethodChannel(messenger, "voicechat/notifications")
        channel.setMethodCallHandler(::handle)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel("messages", "Новые сообщения", NotificationManager.IMPORTANCE_DEFAULT))
            manager.createNotificationChannel(NotificationChannel("incoming_calls", "Входящие звонки", NotificationManager.IMPORTANCE_HIGH))
        }
    }

    private fun allowed(): Boolean =
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            (Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled())

    private fun clear() {
        if (Build.VERSION.SDK_INT >= 23) {
            manager.activeNotifications.filter { it.tag?.startsWith(PREFIX) == true }
                .forEach { manager.cancel(it.tag, it.id) }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("session")
        if (token == null) { result.error("invalid", "Missing session", null); return }
        if (call.method == "begin") {
            clear(); session = token; enabled = false; result.success(null); return
        }
        if (token != session) { result.success(null); return }
        when (call.method) {
            "request" -> {
                val host = activity.get()
                if (allowed()) { result.success(true) }
                else if (Build.VERSION.SDK_INT >= 33 && host != null && !host.isFinishing && pending == null) {
                    pending = token to result
                    host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
                } else result.success(false)
            }
            "enabled" -> {
                enabled = call.argument<Boolean>("enabled") == true
                if (!enabled) clear()
                result.success(null)
            }
            "end" -> { session = null; enabled = false; clear(); result.success(null) }
            "show" -> {
                val room = call.argument<String>("room")
                val id = call.argument<String>("id")
                if (enabled && allowed() && !AppUpdater.foreground && room != null && id != null) {
                    val isCall = call.argument<Boolean>("call") == true
                    val tag = PREFIX + token + ":" + id
                    val intent = Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                        .setAction(tag)
                        .putExtra("notificationSession", token).putExtra("notificationRoom", room)
                    val open = PendingIntent.getActivity(context, 0, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    val builder = if (Build.VERSION.SDK_INT >= 26)
                        Notification.Builder(context, if (isCall) "incoming_calls" else "messages")
                        else Notification.Builder(context).setDefaults(Notification.DEFAULT_SOUND)
                    builder.setSmallIcon(if (isCall) android.R.drawable.sym_action_call else android.R.drawable.sym_action_chat)
                        .setContentTitle("VoiceChat")
                        .setContentText(if (isCall) "Входящий звонок" else "Новое сообщение")
                        .setCategory(if (isCall) Notification.CATEGORY_CALL else Notification.CATEGORY_MESSAGE)
                        .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true)
                        .setOnlyAlertOnce(true).setContentIntent(open)
                    if (Build.VERSION.SDK_INT >= 26 && isCall) builder.setTimeoutAfter(45000)
                    try { manager.notify(tag, 0, builder.build()) }
                    catch (_: SecurityException) { /* Permission may be revoked between checks. */ }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun permissionResult() {
        val request = pending ?: return
        pending = null
        request.second.success(request.first == session && allowed())
    }

    fun open(intent: Intent) {
        val token = intent.getStringExtra("notificationSession") ?: return
        val room = intent.getStringExtra("notificationRoom") ?: return
        intent.removeExtra("notificationSession")
        intent.removeExtra("notificationRoom")
        if (enabled && token == session) {
            channel.invokeMethod("open", mapOf("session" to token, "room" to room))
        }
    }

    fun detach(host: MainActivity) {
        if (activity.get() != host) return
        activity.clear()
        pending?.second?.success(false)
        pending = null
    }
}
