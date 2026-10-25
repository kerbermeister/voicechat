import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let updater = (mainFlutterWindow as? MainFlutterWindow)?.updater,
          updater.installationPending else { return .terminateNow }
    updater.prepareInstallation { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
