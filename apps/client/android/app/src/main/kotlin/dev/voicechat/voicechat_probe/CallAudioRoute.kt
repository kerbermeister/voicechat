package dev.voicechat.voicechat_probe

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The SDK owns audio focus. This boundary selects and verifies the actual OS route. */
class CallAudioRoute(context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var proximity: PowerManager.WakeLock? = null
    private var active = false
    private val monitor = object : Runnable {
        override fun run() {
            if (!active) return
            val receiver = if (Build.VERSION.SDK_INT >= 31) {
                audio.communicationDevice?.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            } else !audio.isSpeakerphoneOn && !audio.isBluetoothScoOn && !audio.isWiredHeadsetOn
            if (receiver && proximity?.isHeld != true) proximity?.acquire()
            if (!receiver && proximity?.isHeld == true) proximity?.release()
            handler.postDelayed(this, 250)
        }
    }

    fun start() {
        if (active) return
        active = true
        if (power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            proximity = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "VoiceChat:proximity")
        }
        monitor.run()
    }

    fun stop() {
        active = false
        handler.removeCallbacks(monitor)
        if (proximity?.isHeld == true) proximity?.release()
        proximity = null
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "routes" -> {
                if (Build.VERSION.SDK_INT >= 31) {
                    result.success(audio.availableCommunicationDevices.map { device ->
                        mapOf("id" to device.id.toString(), "speaker" to (device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER),
                            "label" to when (device.type) {
                                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Громкая связь"
                                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Динамик телефона"
                                else -> device.productName.toString()
                            }, "selected" to (device.id == audio.communicationDevice?.id))
                    })
                } else result.success(listOf(
                    mapOf("id" to "receiver", "speaker" to false, "label" to "Динамик телефона / гарнитура", "selected" to !audio.isSpeakerphoneOn),
                    mapOf("id" to "speaker", "speaker" to true, "label" to "Громкая связь", "selected" to audio.isSpeakerphoneOn)))
            }
            "select" -> {
                val id = call.arguments as? String
                audio.mode = AudioManager.MODE_IN_COMMUNICATION
                if (Build.VERSION.SDK_INT >= 31) {
                    val device = audio.availableCommunicationDevices.firstOrNull { it.id.toString() == id }
                    if (device == null || !audio.setCommunicationDevice(device)) {
                        result.error("audio_route", "Android не разрешил выбранный аудиовыход.", null)
                        return
                    }
                    verify(result, 20) { audio.communicationDevice?.id == device.id }
                } else {
                    if (id !in listOf("speaker", "receiver")) { result.error("audio_route", "Аудиовыход недоступен.", null); return }
                    val speaker = id == "speaker"
                    audio.isSpeakerphoneOn = speaker
                    verify(result, 20) { audio.isSpeakerphoneOn == speaker }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun verify(result: MethodChannel.Result, attempts: Int, matches: () -> Boolean) {
        handler.postDelayed({
            if (matches()) result.success(null)
            else if (attempts > 1) verify(result, attempts - 1, matches)
            else result.error("audio_route", "Android не переключил аудиовыход. Повторите выбор.", null)
        }, 100)
    }
}
