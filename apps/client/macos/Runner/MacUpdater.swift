import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle owns package verification and replacement; Flutter owns the manual UI.
final class MacUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private var updater: SPUUpdater!
  private var started = false
  private var cancellation: (() -> Void)?
  private var choice: ((SPUUserUpdateChoice) -> Void)?
  private var state: [String: Any] = ["phase": "idle"]
  private var active = false
  private(set) var installationPending = false
  private var received: UInt64 = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "voicechat/macos_update", binaryMessenger: messenger)
    super.init()
    updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "info":
        result(["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
      case "check":
        do {
          guard !self.active, !self.started || self.updater.canCheckForUpdates else { result(nil); return }
          guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                let url = URL(string: feed), url.scheme == "https", url.host != nil,
                url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                url.path == "/updates/macos/appcast.xml",
                let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                Data(base64Encoded: key)?.count == 32 else {
            throw NSError(domain: "VoiceChatUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Канал обновлений этой сборки ещё не настроен."])
          }
          self.active = true
          if !self.started { try self.updater.start(); self.started = true }
          self.updater.checkForUpdates()
          result(nil)
        } catch { self.active = false; self.emit("error", error.localizedDescription); result(nil) }
      case "download":
        let reply = self.choice; self.choice = nil
        reply?(.install); result(nil)
      case "install":
        self.prepareInstallation { allowed in
          guard allowed, let reply = self.choice else { return }
          self.choice = nil
          reply(.install)
        }
        result(nil)
      case "cancel": self.cancel(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func emit(_ phase: String, _ message: String = "") {
    state["phase"] = phase
    state["message"] = message
    channel.invokeMethod("state", arguments: state)
  }
  private func cancel() {
    active = false
    let cancel = cancellation; cancellation = nil
    let reply = choice; choice = nil
    cancel?()
    reply?(.skip)
    emit("idle", "Проверка или загрузка отменена.")
  }
  func prepareInstallation(_ completion: @escaping (Bool) -> Void) {
    channel.invokeMethod("prepareInstall", arguments: nil) { response in
      let allowed = response == nil && self.active
      if !allowed {
        self.emit("ready", response as? String ?? "Закройте и снова откройте окно обновления перед установкой.")
      }
      completion(allowed)
    }
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard active, updateCheck == .updates else { throw NSError(domain: "VoiceChatUpdate", code: 2) }
  }
  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
    let feed = URL(string: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")
    guard let url = item.fileURL, url.scheme == "https", url.host == feed?.host,
          url.port == feed?.port, url.user == nil, url.password == nil,
          url.path.hasPrefix("/updates/macos/"), !item.isInformationOnlyUpdate,
          item.contentLength > 0, item.contentLength <= 1024 * 1024 * 1024,
          let build = UInt64(item.versionString),
          let installed = UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
          build > installed else {
      throw NSError(domain: "VoiceChatUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Недопустимый пакет обновления."])
    }
  }
  func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    active = false
    installationPending = false
    choice = nil
    cancellation = nil
  }
  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation
    emit("checking", "Проверяем обновления…")
  }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    cancellation = nil
    guard active else { reply(.skip); return }
    choice = reply
    self.state = ["version": appcastItem.displayVersionString, "build": appcastItem.versionString,
                  "size": appcastItem.contentLength, "notes": String((appcastItem.itemDescription ?? "").prefix(4000)),
                  "minimumOS": appcastItem.minimumSystemVersion ?? "12.0"]
    emit("available", "Доступно обновление.")
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    emit("idle", "Совместимых обновлений нет.")
    acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    emit("error", error.localizedDescription)
    acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation; received = 0
    emit("downloading", "Загружаем обновление…")
  }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { state["size"] = expectedContentLength }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    received += length; state["received"] = received
    emit("downloading", "Загружаем обновление…")
  }
  func showDownloadDidStartExtractingUpdate() {
    cancellation = nil; installationPending = true
    emit("extracting", "Проверяем и распаковываем обновление…")
  }
  func showExtractionReceivedProgress(_ progress: Double) { state["progress"] = progress; emit("extracting", "Распаковываем обновление…") }
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard active else { reply(.skip); return }
    choice = reply
    prepareInstallation { allowed in
      guard allowed, let install = self.choice else { return }
      self.choice = nil
      install(.install)
    }
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    emit("installing", "Устанавливаем обновление…")
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
  func dismissUpdateInstallation() { installationPending = false; choice = nil; cancellation = nil }
  func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true) }
}
