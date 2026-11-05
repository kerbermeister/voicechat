// Injected only into the account-free integration-test build.
package dev.voicechat.voicechat_probe

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class NativeAVMarker(messenger: BinaryMessenger) : AudioProcessingAdapter.ExternalAudioFrameProcessing,
    AudioTrackSink, VideoSink {
    companion object {
        private var instance: NativeAVMarker? = null
        fun install(messenger: BinaryMessenger) { instance = NativeAVMarker(messenger) }
    }
    private val lock = Any()
    @Volatile private var running = false
    @Volatile private var origin = System.nanoTime() / 1e9
    private var sampleCursor = 0L
    @Volatile private var sourceMarker = 0
    @Volatile private var sourceVisible = false
    private var lastSourceAudio = -1
    private var lastSourceVideo = -1
    private val sourceAudioMarkers = mutableListOf<List<Double>>()
    private val sourceVideoMarkers = mutableListOf<List<Double>>()
    private var rate = 48000
    private var speech = ShortArray(0)
    private val lowTones = doubleArrayOf(697.0, 770.0, 852.0, 941.0)
    private val highTones = doubleArrayOf(1209.0, 1336.0, 1477.0, 1633.0)
    private var frameCounter = 0
    private var backgrounds = emptyArray<ByteArray>()
    private val chroma = ByteArray(320 * 180) { 128.toByte() }
    private var source: VideoSource? = null
    private var timer: ScheduledExecutorService? = null
    private var audio: AudioTrack? = null
    private var controlAudio: AudioTrack? = null
    private var video: VideoTrack? = null
    private var lastMarker = -1
    private var peak = 0.0
    // Keep allocations off the audio thread: GC pauses otherwise become part
    // of the latency being measured, especially on an emulated device.
    private val audioPcm = ByteBuffer.allocate(14000 * 480 * 4).order(ByteOrder.LITTLE_ENDIAN)
    private val audioTimes = DoubleArray(14000)
    private var audioCount = 0
    private val controlPcm = ByteBuffer.allocate(14000 * 480 * 4).order(ByteOrder.LITTLE_ENDIAN)
    private val controlTimes = DoubleArray(14000)
    private var controlCount = 0
    private var controlPeak = 0.0
    private val controlSink = object : AudioTrackSink {
        override fun onData(data: ByteBuffer, bits: Int, sampleRate: Int, channels: Int, frames: Int, captureTime: Long) {
            recordAudio(data, bits, sampleRate, channels, frames, true)
        }
    }
    private val framePool = ArrayBlockingQueue<ByteBuffer>(8).apply {
        repeat(8) { add(ByteBuffer.allocateDirect(640 * 360 * 3 / 2)) }
    }
    private val videoMarkers = mutableListOf<List<Double>>()

    init {
        MethodChannel(messenger, "voicechat/native-av-lab").setMethodCallHandler { call, result ->
            val plugin = FlutterWebRTCPlugin.sharedSingleton
            when (call.method) {
                "clock" -> result.success(System.nanoTime() / 1e9)
                "receive" -> { running = true; result.success(null) }
                "create" -> {
                    val stream = plugin.getStreamForId(call.argument<String>("stream"), "")
                    backgrounds = Array(16) { frame -> ByteArray(640 * 360) { index ->
                        val row = index / 640; val col = index % 640
                        val texture = ((col * 13 + row * 7 + frame * 17) xor (col * row)) and 15
                        (80 + texture + (((col + frame * 4) / 16) and 1) * 40 + (((row + frame * 2) / 16) and 1) * 40).toByte()
                    }}
                    val speechBytes = call.argument<ByteArray>("speech") ?: ByteArray(0)
                    val speechBuffer = ByteBuffer.wrap(speechBytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    speech = ShortArray(speechBuffer.remaining()).also { speechBuffer.get(it) }
                    source = plugin.peerConnectionFactory.createVideoSource(false)
                    val track = plugin.peerConnectionFactory.createVideoTrack(UUID.randomUUID().toString(), source)
                    stream.addTrack(track)
                    plugin.audioProcessingController.capturePostProcessing.addProcessor(this)
                    origin = System.nanoTime() / 1e9
                    running = true
                    timer = Executors.newSingleThreadScheduledExecutor().apply {
                        scheduleAtFixedRate({ emitVideo() }, 0, 50000, TimeUnit.MICROSECONDS)
                    }
                    result.success(null)
                }
                "observe" -> {
                    audio = plugin.getRemoteTrack(call.argument<String>("audio")) as? AudioTrack
                    video = plugin.getRemoteTrack(call.argument<String>("video")) as? VideoTrack
                    if (audio == null || (call.hasArgument("video") && video == null)) result.error("fixture", "Missing remote media", null)
                    else { audio!!.addSink(this); video?.addSink(this); result.success(null) }
                }
                "observeControl" -> {
                    val track = plugin.getRemoteTrack(call.argument<String>("audio")) as? AudioTrack
                    if (track == null || controlAudio != null) result.error("fixture", "Missing or duplicate ordinary voice track", null)
                    else { controlAudio = track; track.addSink(controlSink); result.success(null) }
                }
                "gate" -> synchronized(lock) {
                    result.success(mapOf("audio_peak" to peak, "video_markers" to videoMarkers.size,
                        "audio_chunks" to audioCount, "control_audio_peak" to controlPeak))
                }
                "result" -> synchronized(lock) {
                    val chunks = (0 until audioCount).map { index ->
                        mapOf("time" to audioTimes[index], "rate" to 48000, "frames" to 480,
                            "pcm" to audioPcm.array().copyOfRange(index * 1920, (index + 1) * 1920))
                    }
                    val value = mutableMapOf<String, Any>("audio" to chunks, "video" to videoMarkers.toList(), "origin" to origin,
                        "source_audio" to sourceAudioMarkers.toList(), "source_video" to sourceVideoMarkers.toList())
                    if (controlAudio != null) value["control_audio"] = (0 until controlCount).map { index ->
                        mapOf("time" to controlTimes[index], "rate" to 48000, "frames" to 480,
                            "pcm" to controlPcm.array().copyOfRange(index * 1920, (index + 1) * 1920))
                    }
                    result.success(value)
                }
                "stop" -> {
                    running = false
                    timer?.shutdownNow()
                    audio?.removeSink(this); video?.removeSink(this)
                    controlAudio?.removeSink(controlSink)
                    plugin.audioProcessingController.capturePostProcessing.removeProcessor(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun initialize(sampleRateHz: Int, numChannels: Int) { rate = sampleRateHz }
    override fun reset(newRate: Int) { rate = newRate }
    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        if (!running) return
        if (sampleCursor == 0L) origin = System.nanoTime() / 1e9
        val sourceTime = sampleCursor.toDouble() / rate
        synchronized(lock) {
            sourceMarker = (sourceTime / 2).toInt()
            sourceVisible = sourceTime - sourceMarker * 2 < .12
            if (sourceMarker != lastSourceAudio) {
                lastSourceAudio = sourceMarker
                sourceAudioMarkers.add(listOf(sourceMarker.toDouble(), System.nanoTime() / 1e9))
            }
        }
        val samples = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (index in 0 until numFrames) {
            val time = (sampleCursor + index).toDouble() / rate
            val id = (time / 2).toInt()
            val phase = time - id * 2
            val speechIndex = ((phase - .75) * 48000).toInt()
            val value = if (phase < .6 && phase % .15 < .105) {
                val a = (id shr 8) and 15; val b = (id shr 4) and 15; val c = id and 15
                val digit = when (minOf(3, (phase / .15).toInt())) { 0 -> a; 1 -> b; 2 -> c; else -> a xor b xor c }
                (4500 * (sin(2 * PI * lowTones[digit shr 2] * time) + sin(2 * PI * highTones[digit and 3] * time))).toFloat()
            } else if (phase >= .75 && speechIndex < speech.size) speech[speechIndex].toFloat() else 0f
            samples.put(index, value)
        }
        sampleCursor += numFrames
    }
    override fun onData(data: ByteBuffer, bits: Int, sampleRate: Int, channels: Int, frames: Int, captureTime: Long) {
        recordAudio(data, bits, sampleRate, channels, frames, false)
    }
    private fun recordAudio(data: ByteBuffer, bits: Int, sampleRate: Int, channels: Int, frames: Int, control: Boolean) {
        if (!running) return
        check(bits == 16)
        val input = data.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
        val arrived = System.nanoTime() / 1e9
        check(sampleRate == 48000 && frames == 480)
        val chunk = if (control) controlCount else audioCount
        val pcm = if (control) controlPcm else audioPcm
        var chunkPeak = 0.0
        for (index in 0 until frames) {
            val value = input.get(index * channels).toFloat() / 32768
            if (chunk < audioTimes.size) pcm.putFloat((chunk * 480 + index) * 4, value)
            chunkPeak = maxOf(chunkPeak, abs(value.toDouble()))
        }
        synchronized(lock) {
            if (control) {
                controlPeak = maxOf(controlPeak, chunkPeak)
                if (chunk < controlTimes.size) { controlTimes[chunk] = arrived; controlCount++ }
            } else {
                peak = maxOf(peak, chunkPeak)
                if (chunk < audioTimes.size) { audioTimes[chunk] = arrived; audioCount++ }
            }
        }
    }
    override fun onFrame(frame: VideoFrame) {
        if (!running) return
        val pixels = frame.buffer.toI420() ?: return
        try {
            if (pixels.width < 256 || pixels.height < 90) return
            var word = 0L
            for (bit in 0 until 32) {
                val x = (bit % 16 * 16 + 8) * pixels.width / 640
                val y = (bit / 16 * 40 + 20) * pixels.height / 360
                if ((pixels.dataY.get(y * pixels.strideY + x).toInt() and 255) > 128) word = word or (1L shl bit)
            }
            val id = (word and 65535).toInt()
            if (word ushr 16 != (id xor 65535).toLong() || id == lastMarker) return
            lastMarker = id
            synchronized(lock) { videoMarkers.add(listOf(id.toDouble(), System.nanoTime() / 1e9)) }
        } finally { pixels.release() }
    }
    private fun emitVideo() {
        if (!running) return
        val word = synchronized(lock) {
            val id = sourceMarker.toLong() and 65535
            if (sourceVisible) id or ((id xor 65535) shl 16) else 0L
        }
        val storage = framePool.poll() ?: return
        fun plane(offset: Int, length: Int): ByteBuffer = storage.duplicate().apply {
            position(offset); limit(offset + length)
        }.slice()
        val pixels = JavaI420Buffer.wrap(640, 360, plane(0, 640 * 360), 640,
            plane(640 * 360, 320 * 180), 320, plane(640 * 360 + 320 * 180, 320 * 180), 320,
            { check(framePool.offer(storage)) })
        val y = pixels.dataY; val u = pixels.dataU; val v = pixels.dataV
        check(pixels.strideY == 640 && pixels.strideU == 320 && pixels.strideV == 320)
        frameCounter++
        y.put(backgrounds[frameCounter % backgrounds.size])
        for (row in 0 until 80) for (col in 0 until 256) {
                val bit = row / 40 * 16 + col / 16
                y.put(row * pixels.strideY + col, (if (word and (1L shl bit) == 0L) 32 else 220).toByte())
        }
        u.put(chroma); v.put(chroma)
        val captured = System.nanoTime()
        synchronized(lock) {
            val id = (word and 65535).toInt()
            if (word != 0L && id != lastSourceVideo) {
                lastSourceVideo = id
                sourceVideoMarkers.add(listOf(id.toDouble(), captured / 1e9))
            }
        }
        val frame = VideoFrame(pixels, 0, captured)
        try { source!!.capturerObserver.onFrameCaptured(frame) } finally { frame.release() }
    }
}
