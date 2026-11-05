// Injected by the isolated test runner; never compiled into a release app.
import WebRTC
import flutter_webrtc
import AVFoundation

func nativeMarkerAudioSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
  let count = Int(buffer.frameLength)
  let step = buffer.stride
  if let floats = buffer.floatChannelData {
    return (0..<count).map { floats[0][$0 * step] }
  }
  if let shorts = buffer.int16ChannelData {
    return (0..<count).map { Float(shorts[0][$0 * step]) / 32768 }
  }
  return nil
}

final class NativeAVMarker: NSObject, ExternalAudioProcessingDelegate, RTCAudioRenderer, RTCVideoRenderer {
  static var instance: NativeAVMarker?
  static func install(_ messenger: FlutterBinaryMessenger) {
    instance = NativeAVMarker(messenger)
  }
  private let lock = NSLock()
  private var origin = CACurrentMediaTime()
  private var rate = 48000
  private var sampleCursor: Int64 = 0
  private let sourceLock = NSLock()
  private var sourceMarker = 0
  private var sourceVisible = false
  private var lastSourceAudio = -1
  private var lastSourceVideo = -1
  private var sourceAudioMarkers = [[Double]]()
  private var sourceVideoMarkers = [[Double]]()
  private var sourceVideoFrames = [[Double]]()
  private var receivedVideoFrames = [[Double]]()
  private var speech = [Int16]()
  private let lowTones: [Double] = [697, 770, 852, 941]
  private let highTones: [Double] = [1209, 1336, 1477, 1633]
  private var frameCounter = 0
  private var backgrounds = [Data]()
  private let videoQueue = DispatchQueue(label: "voicechat.native-av-marker", qos: .userInteractive)
  private var coherentMarkers = false
  private var timer: DispatchSourceTimer?
  private var source: RTCVideoSource?
  private var capturer: RTCVideoCapturer?
  private var audio: RTCAudioTrack?
  private var video: RTCVideoTrack?
  private var audioChunks = [[String: Any]]()
  private var controlChunks = [[String: Any]]()
  private var controlAudio: RTCAudioTrack?
  private lazy var controlSink = MarkerControlAudioSink(owner: self)
  private var audioPeak: Float = 0
  private var controlPeak: Float = 0
  private var videoMarkers = [[Double]]()
  private var videoRenderClocks = [[Double]]()
  private var lastMarker = -1
  private var running = false
  private let channel: FlutterMethodChannel
  init(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "voicechat/native-av-lab", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, let plugin = FlutterWebRTCPlugin.sharedSingleton() else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "timestampReset":
        guard plugin.peerConnectionFactory == nil,
          let timeout = args["milliseconds"] as? Int, [0, 1000, 2000].contains(timeout) else {
          result(FlutterError(code: "fixture", message: "Configure timestamp recovery before native factory", details: nil)); return
        }
        var parameters = [String]()
        if timeout > 0 { parameters.append("hard_reset_timeout:\(timeout)ms") }
        if args["fullReset"] as? Bool == true { parameters.append("reset_full_cov_on_alarm:true") }
        guard !parameters.isEmpty else {
          result(FlutterError(code: "fixture", message: "Missing timestamp experiment", details: nil)); return
        }
        var trials = "WebRTC-Network-UseNWPathMonitor/Enabled/"
        if args["adaptiveVideo"] as? Bool == true {
          trials += "WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:10000/"
        }
        trials += "WebRTC-TimestampExtrapolatorConfig/\(parameters.joined(separator: ","))/"
        RTCPeerConnectionFactory.configureFieldTrials(trials)
        result(nil)
      case "playout":
        guard plugin.peerConnectionFactory == nil, let delay = args["milliseconds"] as? Int,
          [70, 90, 100, 130].contains(delay) else {
          result(FlutterError(code: "fixture", message: "Configure playout before native factory", details: nil)); return
        }
        let minimum = args["minimum"] as? Int ?? delay
        guard minimum >= 0, minimum <= delay else {
          result(FlutterError(code: "fixture", message: "Invalid video playout bounds", details: nil)); return
        }
        RTCPeerConnectionFactory.configureFieldTrials("WebRTC-Network-UseNWPathMonitor/Enabled/WebRTC-ForcePlayoutDelay/min_ms:\(minimum),max_ms:\(delay)/")
        result(nil)
      case "preferVP8":
        guard let factory = plugin.peerConnectionFactory,
          let peers = plugin.peerConnections?.allValues as? [RTCPeerConnection] else {
          result(FlutterError(code: "fixture", message: "Missing native peers", details: nil)); return
        }
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        let ordered = codecs.filter { $0.name == "VP8" } + codecs.filter { $0.name != "VP8" }
        do {
          for peer in peers { for transceiver in peer.transceivers {
            if transceiver.sender.track?.kind == "video" { try transceiver.setCodecPreferences(ordered, error: ()) }
          }}
          result(nil)
        } catch {
          result(FlutterError(code: "fixture", message: String(describing: (error as NSError).userInfo), details: nil))
        }
      case "clock": result(CACurrentMediaTime())
      case "receive": running = true; result(nil)
      case "create":
        guard let factory = plugin.peerConnectionFactory,
          let id = args["stream"] as? String,
          let stream = plugin.localStreams?[id] as? RTCMediaStream else {
          result(FlutterError(code: "fixture", message: "Missing native stream", details: nil)); return
        }
        coherentMarkers = args["coherent"] as? Bool ?? false
        let source = factory.videoSource()
        backgrounds = Self.makeBackgrounds()
        if let data = args["speech"] as? FlutterStandardTypedData {
          speech = data.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        self.source = source
        capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
        stream.addVideoTrack(track)
        plugin.localTracks?[track.trackId] = LocalVideoTrack(track: track)
        plugin.audioManager?.capturePostProcessingAdapter.addProcessing(self)
        origin = CACurrentMediaTime()
        running = true
        if !coherentMarkers {
          let timer = DispatchSource.makeTimerSource(queue: videoQueue)
          timer.schedule(deadline: .now(), repeating: 1.0 / 20)
          timer.setEventHandler { [weak self] in self?.emitVideo() }
          self.timer = timer
          timer.resume()
        }
        result(nil)
      case "observe":
        audio = plugin.remoteTrack(forId: args["audio"] as? String ?? "") as? RTCAudioTrack
        video = plugin.remoteTrack(forId: args["video"] as? String ?? "") as? RTCVideoTrack
        guard let audio, (args["video"] == nil || video != nil) else {
          result(FlutterError(code: "fixture", message: "Missing remote media", details: nil)); return
        }
        audio.add(self)
        video?.add(self)
        result(nil)
      case "observeControl":
        guard let id = args["audio"] as? String,
          let track = plugin.remoteTrack(forId: id) as? RTCAudioTrack else {
          result(FlutterError(code: "fixture", message: "Missing control audio", details: nil)); return
        }
        controlAudio = track
        track.add(controlSink)
        result(nil)
      case "result":
        lock.lock()
        var value: [String: Any] = ["audio": audioChunks, "video": videoMarkers,
                                  "received_video_frames": receivedVideoFrames,
                                  "video_render_clocks": videoRenderClocks, "origin": origin]
        if controlAudio != nil { value["control_audio"] = controlChunks }
        lock.unlock()
        sourceLock.lock()
        value["source_audio"] = sourceAudioMarkers
        value["source_video"] = sourceVideoMarkers
        value["source_video_frames"] = sourceVideoFrames
        sourceLock.unlock()
        result(value)
      case "gate":
        lock.lock()
        let value: [String: Any] = ["audio_peak": audioPeak, "video_markers": videoMarkers.count,
                                   "audio_chunks": audioChunks.count, "control_audio_peak": controlPeak]
        lock.unlock()
        result(value)
      case "stop":
        running = false
        timer?.cancel(); timer = nil
        audio?.remove(self); video?.remove(self)
        controlAudio?.remove(controlSink)
        plugin.audioManager?.capturePostProcessingAdapter.removeProcessing(self)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) { rate = sampleRateHz }
  private static func makeBackgrounds() -> [Data] {
    var result = [Data]()
    for frame in 0..<16 {
      var bytes = [UInt8](repeating: 80, count: 640 * 360)
      for row in 0..<360 { for col in 0..<640 {
        let texture = ((col * 13 + row * 7 + frame * 17) ^ (col * row)) & 15
        let horizontal = (((col + frame * 4) / 16) & 1) * 40
        let vertical = (((row + frame * 2) / 16) & 1) * 40
        bytes[row * 640 + col] = UInt8(80 + texture + horizontal + vertical)
      }}
      result.append(Data(bytes))
    }
    return result
  }
  func audioProcessingRelease() {}
  func audioProcessingProcess(_ buffer: RTCAudioBuffer) {
    guard running else { return }
    if sampleCursor == 0 { origin = CACurrentMediaTime() }
    // Both markers use the captured-sample clock. An emulated audio device can
    // suspend while wall time advances; independent wall-clock video is then
    // already out of sync before encoding.
    let sourceTime = Double(sampleCursor) / Double(rate)
    sourceLock.lock()
    sourceMarker = Int(sourceTime / 2)
    sourceVisible = sourceTime - Double(sourceMarker * 2) < 0.12
    let markerChanged = sourceMarker != lastSourceAudio
    if markerChanged {
      lastSourceAudio = sourceMarker
      sourceAudioMarkers.append([Double(sourceMarker), CACurrentMediaTime()])
    }
    sourceLock.unlock()
    // Emit exactly 20fps on the sample clock. Adding boundary frames to an
    // independent timer exceeded the encoder cap and could drop the onset.
    if coherentMarkers && sampleCursor % Int64(rate / 20) == 0 {
      videoQueue.async { [weak self] in self?.emitVideo() }
    }
    for ch in 0..<buffer.channels {
      let samples = buffer.rawBuffer(forChannel: ch)
      for index in 0..<buffer.frames {
        let time = Double(sampleCursor + Int64(index)) / Double(rate)
        let id = Int(time / 2)
        let phase = time - Double(id * 2)
        let speechIndex = Int((phase - 0.75) * 48000)
        if phase < 0.6 && phase.truncatingRemainder(dividingBy: 0.15) < 0.105 {
          let a = (id >> 8) & 15, b = (id >> 4) & 15, c = id & 15
          let digit: Int
          switch min(3, Int(phase / 0.15)) {
          case 0: digit = a
          case 1: digit = b
          case 2: digit = c
          default: digit = a ^ b ^ c
          }
          samples[index] = Float(4500 * (sin(2 * .pi * lowTones[digit >> 2] * time) +
                                         sin(2 * .pi * highTones[digit & 3] * time)))
        } else {
          samples[index] = phase >= 0.75 && speechIndex < speech.count ? Float(speech[speechIndex]) : 0
        }
      }
    }
    sampleCursor += Int64(buffer.frames)
  }
  func render(pcmBuffer buffer: AVAudioPCMBuffer) {
    recordAudio(buffer, control: false)
  }
  fileprivate func recordAudio(_ buffer: AVAudioPCMBuffer, control: Bool) {
    guard running else { return }
    guard let samples = nativeMarkerAudioSamples(buffer) else { return }
    let count = samples.count
    let data = samples.withUnsafeBytes { Data($0) }
    lock.lock()
    let chunk: [String: Any] = ["time": CACurrentMediaTime(), "rate": buffer.format.sampleRate,
                                "frames": count, "channels": buffer.format.channelCount,
                                "stride": buffer.stride, "pcm": FlutterStandardTypedData(bytes: data)]
    if control {
      controlPeak = max(controlPeak, samples.map { abs($0) }.max() ?? 0)
      if controlChunks.count < 14000 { controlChunks.append(chunk) }
    } else {
      audioPeak = max(audioPeak, samples.map { abs($0) }.max() ?? 0)
      if audioChunks.count < 14000 { audioChunks.append(chunk) }
    }
    lock.unlock()
  }
  func setSize(_ size: CGSize) {}
  func renderFrame(_ frame: RTCVideoFrame?) {
    guard running, let frame else { return }
    let callbackTime = CACurrentMediaTime()
    let pixels = frame.buffer.toI420()
    guard pixels.width >= 256, pixels.height >= 90 else { return }
    var word: UInt32 = 0
    for bit in 0..<32 {
      let x = ((bit % 16) * 16 + 8) * Int(pixels.width) / 640
      let y = ((bit / 16) * 40 + 20) * Int(pixels.height) / 360
      if pixels.dataY[y * Int(pixels.strideY) + x] > 128 { word |= 1 << bit }
    }
    let encoded = word & 0xffff
    let id = Int(encoded & 0xfff)
    guard (word >> 16) == (encoded ^ 0xffff), id != lastMarker else { return }
    lastMarker = id
    lock.lock()
    videoMarkers.append([Double(id), CACurrentMediaTime()])
    receivedVideoFrames.append([Double(id), Double(encoded >> 12)])
    videoRenderClocks.append([Double(id), callbackTime, Double(frame.timeStampNs) / 1e9])
    lock.unlock()
  }
  private func emitVideo() {
    guard running, let source, let capturer else { return }
    sourceLock.lock()
    let id = UInt32(sourceMarker & 0xffff)
    let visible = sourceVisible
    sourceLock.unlock()
    let pixels = RTCI420Buffer(width: 640, height: 360)
    let y = UnsafeMutablePointer(mutating: pixels.dataY)
    let u = UnsafeMutablePointer(mutating: pixels.dataU)
    let v = UnsafeMutablePointer(mutating: pixels.dataV)
    frameCounter += 1
    let encoded = id | (UInt32(frameCounter & 15) << 12)
    let word = visible ? encoded | ((encoded ^ 0xffff) << 16) : 0
    backgrounds[frameCounter % backgrounds.count].withUnsafeBytes { bytes in
      for row in 0..<360 {
        memcpy(y + row * Int(pixels.strideY), bytes.baseAddress! + row * 640, 640)
      }
    }
    for row in 0..<80 {
      for col in 0..<16 {
        let bit = (row / 40) * 16 + col
        memset(y + row * Int(pixels.strideY) + col * 16, (word & (1 << bit)) == 0 ? 32 : 220, 16)
      }
    }
    u.initialize(repeating: 128, count: Int(pixels.strideU) * 180)
    v.initialize(repeating: 128, count: Int(pixels.strideV) * 180)
    let captured = CACurrentMediaTime()
    sourceLock.lock()
    if word != 0 { sourceVideoFrames.append([Double(id), Double(frameCounter & 15), captured]) }
    if word != 0 && Int(id) != lastSourceVideo {
      lastSourceVideo = Int(id)
      sourceVideoMarkers.append([Double(id), captured])
    }
    sourceLock.unlock()
    source.capturer(capturer, didCapture: RTCVideoFrame(buffer: pixels, rotation: ._0, timeStampNs: Int64(captured * 1e9)))
  }
}

private final class MarkerControlAudioSink: NSObject, RTCAudioRenderer {
  private weak var owner: NativeAVMarker?
  init(owner: NativeAVMarker) { self.owner = owner; super.init() }
  func render(pcmBuffer buffer: AVAudioPCMBuffer) { owner?.recordAudio(buffer, control: true) }
}
