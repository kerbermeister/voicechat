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

/** Держит notification; MediaProjection и его разрешением владеет flutter_webrtc. */
class ScreenService : Service() {
    companion object {
        var pending: MethodChannel.Result? = null
        var running = false; private set
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, "voicechat/screen").invokeMethod("stop", null)
            }
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel("screen", "Демонстрация экрана", NotificationManager.IMPORTANCE_LOW))
            }
            val stop = PendingIntent.getService(this, 2, Intent(this, ScreenService::class.java).setAction("stop"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val open = PendingIntent.getActivity(this, 3, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, "screen") else Notification.Builder(this)
            val notification = builder.setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("VoiceChat: показ экрана").setContentText("Экран передаётся участникам звонка")
                .setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(true).setContentIntent(open)
                .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Остановить показ", stop).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(7358, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else startForeground(7358, notification)
            running = true
            pending?.success(null)
        } catch (_: Exception) {
            pending?.error("projection_service", "Cannot start screen service", null)
            stopSelf()
        } finally { pending = null }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        running = false
        pending?.error("projection_stopped", "Screen service stopped", null)
        pending = null
        FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, "voicechat/screen").invokeMethod("stop", null)
        }
        super.onDestroy()
    }
}
