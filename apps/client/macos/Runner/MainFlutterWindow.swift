import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private(set) var updater: MacUpdater?
  private var notifications: DesktopNotifications?
  private var noteCamera: NoteCamera?
  private var platformFiles: PlatformFiles?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    platformFiles = PlatformFiles(messenger: flutterViewController.engine.binaryMessenger)
    noteCamera = NoteCamera(registrar: flutterViewController.registrar(forPlugin: "VoiceChatCamera"))
    notifications = DesktopNotifications(messenger: flutterViewController.engine.binaryMessenger)
    updater = MacUpdater(messenger: flutterViewController.engine.binaryMessenger)
    title = "VoiceChat"
    setContentSize(NSSize(width: 1100, height: 760))
    minSize = NSSize(width: 390, height: 500)

    super.awakeFromNib()
  }
}
