import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingDestination {
  private(set) var updater: MacUpdater?
  private var notifications: DesktopNotifications?
  private var noteCamera: NoteCamera?
  private var platformFiles: PlatformFiles?
  private var fileDropChannel: FlutterMethodChannel?
  private var dropTarget: NSRect?
  private var dropHovering = false
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    platformFiles = PlatformFiles(messenger: flutterViewController.engine.binaryMessenger)
    let dropChannel = FlutterMethodChannel(name: "voicechat/file-drop",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fileDropChannel = dropChannel
    dropChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "target" else { result(FlutterMethodNotImplemented); return }
      self?.dropTarget = Self.dropRect(call.arguments)
      if self?.dropTarget == nil { self?.showDropHover(false) }
      result(nil)
    }
    registerForDraggedTypes([.fileURL])
    noteCamera = NoteCamera(registrar: flutterViewController.registrar(forPlugin: "VoiceChatCamera"))
    notifications = DesktopNotifications(messenger: flutterViewController.engine.binaryMessenger)
    updater = MacUpdater(messenger: flutterViewController.engine.binaryMessenger)
    title = "VoiceChat"
    setContentSize(NSSize(width: 1100, height: 760))
    minSize = NSSize(width: 390, height: 500)

    super.awakeFromNib()
    // Keep the native title bar outside Flutter's content and retain standard controls.
    styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
    styleMask.remove(.fullSizeContentView)
    titleVisibility = .visible
    titlebarAppearsTransparent = false
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = false
    }
  }

  static func dropRect(_ arguments: Any?) -> NSRect? {
    guard let args = arguments as? [String: Double], let x = args["x"], let y = args["y"],
      let width = args["width"], let height = args["height"],
      [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { return nil }
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private func dropPoint(_ sender: NSDraggingInfo) -> NSPoint? {
    guard let view = contentViewController?.view else { return nil }
    let point = view.convert(sender.draggingLocation, from: nil)
    return NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
  }

  private func acceptsDrop(_ sender: NSDraggingInfo) -> Bool {
    guard sender.draggingSourceOperationMask.contains(.copy),
      sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]),
      let point = dropPoint(sender), let target = dropTarget else { return false }
    return target.contains(point)
  }

  private func showDropHover(_ value: Bool) {
    guard value != dropHovering else { return }
    dropHovering = value
    fileDropChannel?.invokeMethod("hover", arguments: value)
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let accepted = acceptsDrop(sender)
    showDropHover(accepted)
    return accepted ? .copy : []
  }
  func draggingExited(_ sender: NSDraggingInfo?) { showDropHover(false) }
  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptsDrop(sender) }
  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { showDropHover(false) }
    guard acceptsDrop(sender), let point = dropPoint(sender), let files = platformFiles,
      let channel = fileDropChannel,
      let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
    do {
      let selections = try files.select(urls)
      channel.invokeMethod("drop", arguments: ["x": point.x, "y": point.y, "files": selections]) { result in
        if result as? Bool != true {
          for selected in selections { if let id = selected["uri"] as? String { files.release(id) } }
        }
      }
      return true
    } catch { return false }
  }
}
