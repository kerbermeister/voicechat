import Cocoa
import FlutterMacOS
import UserNotifications

final class DesktopNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let channel: FlutterMethodChannel
  private var session: String?
  private var enabled = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "voicechat/notifications", binaryMessenger: messenger)
    super.init()
    center.delegate = self
    clear()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any], let token = args["session"] as? String else { result(nil); return }
      if call.method == "begin" {
        self.clear(); self.session = token; self.enabled = false; result(nil); return
      }
      guard token == self.session else { result(nil); return }
      switch call.method {
      case "request":
        self.center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
          DispatchQueue.main.async { result(allowed && self.session == token) }
        }
      case "enabled":
        self.enabled = args["enabled"] as? Bool == true
        if !self.enabled { self.clear() }
        result(nil)
      case "end":
        self.session = nil; self.enabled = false; self.clear(); result(nil)
      case "show":
        guard self.enabled, !(NSApp.isActive && NSApp.keyWindow?.isVisible == true),
              let room = args["room"] as? String, let id = args["id"] as? String else { result(nil); return }
        let content = UNMutableNotificationContent()
        content.title = "VoiceChat"
        content.body = args["call"] as? Bool == true ? "Входящий звонок" : "Новое сообщение"
        content.sound = .default
        content.userInfo = ["session": token, "room": room]
        let identifier = token + ":" + id
        self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
          DispatchQueue.main.async {
            if self.session != token || !self.enabled {
              self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
              self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            result(error == nil ? nil : FlutterError(code: "notification", message: "Уведомление не доставлено.", details: nil))
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func clear() {
    center.removeAllPendingNotificationRequests()
    center.removeAllDeliveredNotifications()
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      defer { completionHandler() }
      let data = response.notification.request.content.userInfo
      guard let token = data["session"] as? String, token == self.session,
            let room = data["room"] as? String else { return }
      NSApp.activate(ignoringOtherApps: true)
      (NSApp.delegate as? AppDelegate)?.mainFlutterWindow?.makeKeyAndOrderFront(nil)
      self.channel.invokeMethod("open", arguments: ["session": token, "room": room])
    }
  }
}
