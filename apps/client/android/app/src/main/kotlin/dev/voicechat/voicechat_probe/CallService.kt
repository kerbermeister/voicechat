package dev.voicechat.voicechat_probe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class CallService : Service() {
    companion object { var running = false; private set }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        running = true
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel("calls", "Текущий звонок", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val end = PendingIntent.getService(this, 1, Intent(this, CallService::class.java).setAction("end"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, "calls") else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.sym_action_call)
            .setContentTitle("VoiceChat").setContentText("Идёт защищённый звонок")
            .setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true).setContentIntent(open).addAction(android.R.drawable.ic_menu_close_clear_cancel, "Завершить", end).build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(7357, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else { startForeground(7357, notification) }
        } catch (_: SecurityException) {
            FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, "voicechat/calls").invokeMethod("backgroundUnavailable", null)
            }
            stopSelf()
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "end") {
            val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
            if (engine == null) stopSelf() else {
                MethodChannel(engine.dartExecutor.binaryMessenger, "voicechat/calls").invokeMethod("end", null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) { stopSelf() }
                        override fun error(code: String, message: String?, details: Any?) { stopSelf() }
                        override fun notImplemented() { stopSelf() }
                    })
            }
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        running = false
        // Matrix must finish the encrypted hangup/history write after the microphone stops.
        super.onDestroy()
    }
}
