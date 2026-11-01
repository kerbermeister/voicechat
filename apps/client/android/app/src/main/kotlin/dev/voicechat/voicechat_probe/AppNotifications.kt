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
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.Settings
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.io.IOException

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
    private var pendingPush: Intent? = null
    private var account: String? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
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
            account = call.argument<String>("account")
            if (PushNotifications.account(context) != null && PushNotifications.account(context) != account) {
                PushNotifications.clear(context)
                pendingPush = null
            }
            clear(); session = token; enabled = false; result.success(null); return
        }
        if (token != session) { result.success(null); return }
        when (call.method) {
            "requestCallScreen" -> {
                if (Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent()) result.success(true)
                else {
                    try {
                        activity.get()?.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                            Uri.parse("package:" + context.packageName)))
                    } catch (_: Exception) { /* The OS may not expose this settings page. */ }
                    result.success(false)
                }
            }
            "pushToken" -> {
                FirebaseMessaging.getInstance().isAutoInitEnabled = true
                FirebaseMessaging.getInstance().token
                    .addOnSuccessListener { result.success(it) }
                    .addOnFailureListener { result.error("fcm_unavailable", "Firebase token unavailable", null) }
            }
            "pushBind" -> {
                try {
                    PushNotifications.configure(context, account ?: "", call.argument<String>("base")!!, call.argument<String>("binding")!!)
                    result.success(null)
                } catch (_: Exception) { result.error("invalid", "Invalid push binding", null) }
            }
            "pushClear" -> { PushNotifications.clear(context); result.success(null) }
            "takePush" -> {
                val intent = pendingPush
                pendingPush = null
                if (intent == null || PushNotifications.account(context) != account) { result.success(null); return }
                val binding = intent.getStringExtra("pushBinding") ?: ""
                val notice = intent.getStringExtra("pushNotice") ?: ""
                worker.execute {
                    var retry = false
                    val data = try { PushNotifications.resolve(context, binding, notice) }
                        catch (_: IOException) { retry = true; null }
                        catch (_: Exception) { null }
                    main.post {
                        if (retry && session == token && pendingPush == null &&
                            binding == PushNotifications.binding(context) &&
                            intent.getLongExtra("pushExpires", 0) * 1000 > System.currentTimeMillis()) pendingPush = intent
                        if (session != token || data == null || data.optString("kind") == "dismiss") result.success(null)
                        else result.success(mapOf("room" to data.optString("room"),
                            "session" to data.optString("session"), "expires" to data.optLong("expires"),
                            "video" to data.optBoolean("video"),
                            "action" to intent.getStringExtra("pushAction")))
                    }
                }
            }
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
                if (enabled && allowed() && !AppUpdater.foreground && room != null && id != null && PushNotifications.binding(context) == null) {
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
        if (intent.hasExtra("pushNotice")) {
            if (intent.getStringExtra("pushBinding") != PushNotifications.binding(context)) return
            if (intent.getStringExtra("pushAction") == "answer") {
                manager.cancel(intent.getStringExtra("pushTag"), 0)
            }
            pendingPush = Intent(intent)
            intent.removeExtra("pushNotice")
            if (::channel.isInitialized) channel.invokeMethod("pushAvailable", null)
            return
        }
        val token = intent.getStringExtra("notificationSession") ?: return
        val room = intent.getStringExtra("notificationRoom") ?: return
        intent.removeExtra("notificationSession")
        intent.removeExtra("notificationRoom")
        if (enabled && token == session) {
            channel.invokeMethod("open", mapOf("session" to token, "room" to room))
        }
    }

    fun tokenChanged() {
        main.post { if (::channel.isInitialized) channel.invokeMethod("tokenChanged", null) }
    }

    fun detach(host: MainActivity) {
        if (activity.get() != host) return
        activity.clear()
        pending?.second?.success(false)
        pending = null
    }
}
