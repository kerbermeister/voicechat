import AVFoundation
import FlutterMacOS

/// Each recording owns a separate capture session; late permission/export callbacks
/// cannot mutate a newer recording after the old controller is disposed.
final class NoteCamera {
  private let registry: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var capture: NoteCapture?
  init(registrar: FlutterPluginRegistrar) {
    registry = registrar.textures
    channel = FlutterMethodChannel(name: "voicechat/camera", binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "cameras" {
        result(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices.map { $0.uniqueID })
        return
      }
      if call.method == "create" {
        guard self.capture == nil else { result(FlutterError(code: "busy", message: "Камера уже используется.", details: nil)); return }
        self.capture = NoteCapture(registry: self.registry, channel: self.channel)
      }
      guard let capture = self.capture else { result(FlutterError(code: "closed", message: "Камера закрыта.", details: nil)); return }
      capture.handle(call) { value in
        if call.method == "dispose", self.capture === capture { self.capture = nil }
        result(value)
      }
    }
  }
}

private final class NoteCapture: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
  private let registry: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "voicechat.camera")
  private let session = AVCaptureSession()
  private let movie = AVCaptureMovieFileOutput()
  private let frames = AVCaptureVideoDataOutput()
  private let lock = NSLock()
  private var pixel: CVPixelBuffer?
  private var texture: Int64 = -1
  private var input: AVCaptureDeviceInput?
  private var cameraName = ""
  private var audio = true
  private let stateLock = NSLock()
  private var _disposed = true
  private var disposed: Bool {
    get { stateLock.lock(); defer { stateLock.unlock() }; return _disposed }
    set { stateLock.lock(); _disposed = newValue; stateLock.unlock() }
  }
  private var starting: FlutterResult?
  private var stopping: FlutterResult?
  private var exporting: AVAssetExportSession?

  init(registry: FlutterTextureRegistry, channel: FlutterMethodChannel) {
    self.registry = registry
    self.channel = channel
    super.init()
  }

  private func fail(_ result: @escaping FlutterResult, _ message: String) {
    DispatchQueue.main.async { result(FlutterError(code: "camera", message: message, details: nil)) }
  }
  private func complete(_ result: @escaping FlutterResult, _ value: Any? = nil) {
    DispatchQueue.main.async { result(value) }
  }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "cameras" {
      result(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices.map { $0.uniqueID }); return
    }
    if call.method == "create" {
      guard texture == -1, let name = args["name"] as? String else {
        fail(result, "Камера уже используется."); return
      }
      cameraName = name
      audio = args["audio"] as? Bool == true
      disposed = false
      texture = registry.register(self)
      result(texture); return
    }
    guard texture != -1, call.method == "switch" || (args["id"] as? Int64) == texture else {
      fail(result, "Камера недоступна."); return
    }
    if call.method == "initialize" {
      AVCaptureDevice.requestAccess(for: .video) { [weak self] video in
        guard let self = self else { return }
        guard video else { self.fail(result, "Разрешите доступ к камере в настройках macOS."); return }
        if self.audio {
          AVCaptureDevice.requestAccess(for: .audio) { allowed in
            if allowed { self.configure(result) }
            else { self.fail(result, "Разрешите доступ к микрофону в настройках macOS.") }
          }
        } else { self.configure(result) }
      }
      return
    }
    if call.method == "dispose" {
      let previous = texture
      texture = -1
      // Set before queued permission/session work can start a new capture.
      disposed = true
      registry.unregisterTexture(previous)
      queue.async {
        self.exporting?.cancelExport()
        self.movie.stopRecording()
        self.session.stopRunning()
        self.session.beginConfiguration()
        for input in self.session.inputs { self.session.removeInput(input) }
        for output in self.session.outputs { self.session.removeOutput(output) }
        self.session.commitConfiguration()
        self.input = nil
        self.lock.lock(); self.pixel = nil; self.lock.unlock()
        self.complete(result)
      }
      return
    }
    queue.async {
      guard !self.disposed else { self.fail(result, "Камера закрыта."); return }
      do {
        switch call.method {
        case "start":
          guard self.session.isRunning, !self.movie.isRecording, self.starting == nil, self.exporting == nil else {
            throw NSError(domain: "camera", code: 1)
          }
          let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VoiceChatRecordings", isDirectory: true)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          let url = root.appendingPathComponent("REC\(UInt64(Date().timeIntervalSince1970 * 1000000)).mov")
          self.starting = result
          self.movie.startRecording(to: url, recordingDelegate: self)
        case "stop":
          guard self.movie.isRecording, self.stopping == nil else { throw NSError(domain: "camera", code: 2) }
          self.stopping = result
          self.movie.stopRecording()
        case "switch":
          guard let name = args["name"] as? String, let device = AVCaptureDevice(uniqueID: name), let old = self.input else {
            throw NSError(domain: "camera", code: 3)
          }
          let next = try AVCaptureDeviceInput(device: device)
          self.session.beginConfiguration()
          self.session.removeInput(old)
          if self.session.canAddInput(next) {
            self.session.addInput(next); self.input = next
          } else {
            self.session.addInput(old)
            self.session.commitConfiguration()
            throw NSError(domain: "camera", code: 4)
          }
          self.session.commitConfiguration()
          self.complete(result)
        default: self.complete(result, FlutterMethodNotImplemented)
        }
      } catch { self.fail(result, "Операция с камерой не выполнена. Повторите или отмените запись.") }
    }
  }

  private func configure(_ result: @escaping FlutterResult) {
    queue.async {
      guard !self.disposed else { self.fail(result, "Камера закрыта."); return }
      do {
        guard let device = AVCaptureDevice(uniqueID: self.cameraName) else { throw NSError(domain: "camera", code: 5) }
        let video = try AVCaptureDeviceInput(device: device)
        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }
        self.session.sessionPreset = .vga640x480
        guard self.session.canAddInput(video) else { throw NSError(domain: "camera", code: 6) }
        self.session.addInput(video); self.input = video
        if self.audio {
          guard let microphone = AVCaptureDevice.default(for: .audio) else { throw NSError(domain: "camera", code: 7) }
          let audioInput = try AVCaptureDeviceInput(device: microphone)
          guard self.session.canAddInput(audioInput) else { throw NSError(domain: "camera", code: 8) }
          self.session.addInput(audioInput)
        }
        self.frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        self.frames.alwaysDiscardsLateVideoFrames = true
        self.frames.setSampleBufferDelegate(self, queue: self.queue)
        guard self.session.canAddOutput(self.frames), self.session.canAddOutput(self.movie) else { throw NSError(domain: "camera", code: 9) }
        self.session.addOutput(self.frames)
        self.session.addOutput(self.movie)
        self.queue.async {
          guard !self.disposed else { self.fail(result, "Камера закрыта."); return }
          self.session.startRunning()
          self.complete(result, ["width": 640, "height": 480])
        }
      } catch { self.fail(result, "Не удалось открыть камеру и микрофон.") }
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock(); defer { lock.unlock() }
    return pixel.map { Unmanaged.passRetained($0) }
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard !disposed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.lock(); pixel = buffer; lock.unlock()
    DispatchQueue.main.async { if self.texture != -1 { self.registry.textureFrameAvailable(self.texture) } }
  }
  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    queue.async {
      if let result = self.starting { self.starting = nil; self.complete(result) }
    }
  }
  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
    queue.async {
      if let result = self.starting { self.starting = nil; self.fail(result, "Не удалось начать запись.") }
      let result = self.stopping
      self.stopping = nil
      guard !self.disposed, let result = result, error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true else {
        try? FileManager.default.removeItem(at: url)
        if let result = result { self.fail(result, "Запись прервана.") }
        else if !self.disposed {
          DispatchQueue.main.async { self.channel.invokeMethod("error", arguments: ["id": self.texture, "message": "Запись прервана. Повторите попытку."]) }
        }
        return
      }
      let target = url.deletingPathExtension().appendingPathExtension("mp4")
      guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetHighestQuality) else {
        try? FileManager.default.removeItem(at: url)
        self.fail(result, "Не удалось подготовить видео."); return
      }
      self.exporting = exporter
      exporter.outputURL = target
      exporter.outputFileType = .mp4
      exporter.shouldOptimizeForNetworkUse = true
      exporter.exportAsynchronously {
        self.queue.async {
          self.exporting = nil
          try? FileManager.default.removeItem(at: url)
          if exporter.status == .completed && !self.disposed { self.complete(result, target.path) }
          else {
            try? FileManager.default.removeItem(at: target)
            self.fail(result, "Не удалось сохранить видео.")
          }
        }
      }
    }
  }
}
