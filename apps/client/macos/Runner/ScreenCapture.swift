import Cocoa
import OSLog
import FlutterMacOS
import ScreenCaptureKit
import WebRTC
import flutter_webrtc

// The system picker grants access to the selected content for this session.
// CGPreflightScreenCaptureAccess describes the older blanket permission and
// must not veto a picker-authorized stream on macOS 14 and later.
@available(macOS 14.0, *)
final class ScreenCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
  private let logger = Logger(subsystem: "dev.voicechat.client", category: "screen-capture")
  private var startCompleted = false
  private var sampleCount = 0
  private var frameStatuses: [Int: Int] = [:]
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "voicechat.screen")
  private let picker = SCContentSharingPicker.shared
  private var pending: FlutterResult?
  private var stream: SCStream?
  private var source: RTCVideoSource?
  private var capturer: RTCVideoCapturer?
  private var streamID: String?
  private var frameDeadline: DispatchWorkItem?
  private var stopped = true

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "voicechat/screen", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pickerSupported": result(true)
      case "start": self.start(call.arguments, result)
      case "cancelSelection":
        if self.pending != nil && call.arguments as? String == self.streamID {
          self.stop { result(nil) }
        } else { result(nil) }
      case "stop": self.stop { result(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard stopped, pending == nil,
      let args = arguments as? [String: Any], let id = args["streamId"] as? String,
      FlutterWebRTCPlugin.sharedSingleton()?.localStreams?[id] != nil else {
      result(FlutterError(code: "screenBusy", message: "Захват экрана уже запущен.", details: nil)); return
    }
    stopped = false
    startCompleted = false
    sampleCount = 0
    frameStatuses = [:]
    pending = result
    streamID = id
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
    configuration.allowsChangingSelectedContent = false
    picker.defaultConfiguration = configuration
    picker.maximumStreamCount = 1
    picker.add(self)
    picker.isActive = true
    picker.present()
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    fail("screenCancelled", "Выбор экрана отменён.")
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    logError(error, stage: "picker")
    fail("screenCaptureFailed", "Не удалось открыть системный выбор экрана.")
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
    DispatchQueue.main.async { self.capture(filter) }
  }

  private func capture(_ filter: SCContentFilter) {
    guard !stopped, pending != nil, stream == nil, let id = streamID,
      let plugin = FlutterWebRTCPlugin.sharedSingleton(),
      let factory = plugin.peerConnectionFactory, let media = plugin.localStreams?[id] as? RTCMediaStream else { return }
    let source = factory.videoSource(forScreenCast: true)
    self.source = source
    capturer = RTCVideoCapturer(delegate: source)
    let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
    media.addVideoTrack(track)
    plugin.localTracks?[track.trackId] = LocalVideoTrack(track: track)
    registerStopHandler(plugin, trackID: track.trackId, streamID: id)
    let config = SCStreamConfiguration()
    // Preserve aspect ratio and cap the source before WebRTC encoding.
    let size = filter.contentRect.size
    let scale = min(CGFloat(filter.pointPixelScale), 1920 / max(1, size.width), 1080 / max(1, size.height))
    config.width = max(2, Int(size.width * scale) / 2 * 2)
    config.height = max(2, Int(size.height * scale) / 2 * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.capturesAudio = false
    let capture = SCStream(filter: filter, configuration: config, delegate: self)
    self.stream = capture
    do {
      try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
      let deadline = DispatchWorkItem { [weak self, weak capture] in
        guard let self, let capture, capture === self.stream else { return }
        self.logger.error("Capture timeout: started=\(self.startCompleted), samples=\(self.sampleCount), statuses=\(String(describing: self.frameStatuses), privacy: .public)")
        self.fail("screenNoFrames", "macOS не передала кадры выбранного экрана.")
      }
      frameDeadline = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
      logger.notice("Starting capture: width=\(config.width), height=\(config.height)")
      capture.startCapture { [weak self, weak capture] error in
        DispatchQueue.main.async {
          guard let self, let capture, capture === self.stream, !self.stopped else { return }
          if let error {
            self.logError(error, stage: "start")
            self.fail("screenCaptureFailed", "macOS не смогла начать показ выбранного экрана.")
          } else {
            self.startCompleted = true
            self.logger.notice("Capture start completed")
          }
        }
      }
    } catch {
      logError(error, stage: "output")
      fail("screenCaptureFailed", "Не удалось подключить захват экрана.")
    }
  }

  func registerStopHandler(_ plugin: FlutterWebRTCPlugin, trackID: String, streamID id: String) {
    let stopHandler: @convention(block) (@escaping CompletionHandler) -> Void = { [weak self] completion in
      DispatchQueue.main.async {
        guard let self, self.streamID == id else { completion(); return }
        self.stop(completion)
      }
    }
    // NSMutableDictionary erases the typedef. A Swift closure boxes as __SwiftValue;
    // Objective-C invokes this value as a block, so preserve the block ABI.
    plugin.videoCapturerStopHandlers?[trackID] = stopHandler
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    // Keep capture ownership, diagnostics and shutdown on the method-call queue.
    DispatchQueue.main.async {
      guard !self.stopped, stream === self.stream, let source = self.source, let capturer = self.capturer else { return }
      self.sampleCount += 1
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
      let status = attachments?.first?[.status] as? Int ?? -1
      self.frameStatuses[status, default: 0] += 1
      guard let pixel = Self.frame(from: buffer) else { return }
      if self.pending != nil { self.logger.notice("First usable screen frame: status=\(status)") }
      let timestamp = Int64(CMTimeGetSeconds(buffer.presentationTimeStamp) * 1_000_000_000)
      source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0, timeStampNs: timestamp))
      self.frameDeadline?.cancel()
      self.frameDeadline = nil
      if let result = self.pending { self.pending = nil; result(nil) }
    }
  }

  static func frame(from buffer: CMSampleBuffer) -> CVPixelBuffer? {
    guard buffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int,
      [SCFrameStatus.complete.rawValue, SCFrameStatus.started.rawValue].contains(status) else { return nil }
    return buffer.imageBuffer
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async {
      guard stream === self.stream else { return }
      self.logError(error, stage: "stream-stop")
      self.fail("screenCaptureStopped", "Система остановила показ экрана.")
    }
  }

  // Do not log error descriptions/userInfo: they may contain window titles or paths.
  private func logError(_ error: Error, stage: String) {
    let error = error as NSError
    logger.error("Capture error: stage=\(stage, privacy: .public), domain=\(error.domain, privacy: .public), code=\(error.code)")
  }

  private func fail(_ code: String, _ message: String) {
    DispatchQueue.main.async {
      guard !self.stopped else { return }
      let result = self.pending
      self.pending = nil
      let id = self.streamID
      self.stop {
        if let result { result(FlutterError(code: code, message: message, details: nil)) }
        else { self.channel.invokeMethod("stop", arguments: id) }
      }
    }
  }

  private func stop(_ completion: @escaping () -> Void) {
    stopped = true
    frameDeadline?.cancel()
    frameDeadline = nil
    picker.remove(self)
    picker.isActive = false
    let capture = stream
    stream = nil
    source = nil
    capturer = nil
    streamID = nil
    if let result = pending {
      pending = nil
      result(FlutterError(code: "screenCancelled", message: "Показ отменён.", details: nil))
    }
    if let capture {
      // Keep the SCStream alive until its asynchronous stop has completed.
      capture.stopCapture { [capture] error in
        withExtendedLifetime(capture) {
          if let error { self.logError(error, stage: "stop") }
          DispatchQueue.main.async(execute: completion)
        }
      }
    } else { completion() }
  }
}
