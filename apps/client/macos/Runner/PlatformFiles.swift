import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Opaque selection IDs keep Dart callers confined to files the user selected.
final class PlatformFiles {
  private struct Selection {
    let url: URL
    let scoped: Bool
  }
  private struct Save {
    let destination: URL
    let temporary: URL
    let directory: URL
    let handle: FileHandle
    let scoped: Bool
  }
  private var selections: [String: Selection] = [:]
  private var saves: [String: Save] = [:]
  private var pickerOpen = false
  private var channels: [FlutterMethodChannel] = []

  init(messenger: FlutterBinaryMessenger) {
    for name in ["files", "images", "save", "links"] {
      let channel = FlutterMethodChannel(name: "voicechat/\(name)", binaryMessenger: messenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        do { try self.handle(name, call, result) }
        catch { result(FlutterError(code: "file", message: "Не удалось выполнить операцию с файлом или ссылкой.", details: nil)) }
      }
      channels.append(channel)
    }
  }

  private func handle(_ channel: String, _ call: FlutterMethodCall, _ result: @escaping FlutterResult) throws {
    let args = call.arguments as? [String: Any] ?? [:]
    if channel == "links" {
      guard let value = call.arguments as? String, let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw invalid() }
      if call.method == "open" {
        guard NSWorkspace.shared.open(url) else { throw invalid() }
      } else if call.method == "share" {
        guard let view = NSApp.keyWindow?.contentView else { throw invalid() }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      } else { result(FlutterMethodNotImplemented); return }
      result(nil)
      return
    }
    switch call.method {
    case "choose" where channel == "files" || channel == "images":
      guard !pickerOpen, let maximum = args["max_count"] as? Int,
            (1...(channel == "images" ? 64 : 20)).contains(maximum) else { throw invalid() }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = maximum > 1
      if channel == "images" { panel.allowedContentTypes = [.image] }
      else if args["video"] as? Bool == true { panel.allowedContentTypes = [.movie] }
      pickerOpen = true
      panel.begin { [weak self] response in
        guard let self = self else { return }
        self.pickerOpen = false
        guard response == .OK else { result(nil); return }
        guard panel.urls.count <= maximum else {
          result(FlutterError(code: "limit", message: "Выбрано слишком много файлов.", details: nil)); return
        }
        var added: [String] = []
        do {
          var files: [[String: Any]] = []
          files = try self.select(panel.urls)
          added = files.compactMap { $0["uri"] as? String }
          result(channel == "images" ? added : files)
        } catch {
          for id in added { self.release(id) }
          result(FlutterError(code: "read", message: "Выбранный файл недоступен.", details: nil))
        }
      }
    case "release" where channel == "files":
      if let id = args["uri"] as? String { release(id) }
      result(nil)
    case "read" where channel == "files" || channel == "images":
      guard let id = args["uri"] as? String, let selected = selections[id] else { throw invalid() }
      let handle = try FileHandle(forReadingFrom: selected.url)
      defer { try? handle.close(); if channel == "images" { release(id) } }
      let size = try handle.seekToEnd()
      if channel == "images" {
        guard let limit = args["max_bytes"] as? Int, (1...10 * 1024 * 1024).contains(limit), size <= UInt64(limit) else { throw invalid() }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: Int(size)) ?? Data()
        guard data.count == Int(size) else { throw invalid() }
        result(["name": selected.url.lastPathComponent, "bytes": FlutterStandardTypedData(bytes: data)])
      } else {
        guard let start = args["start"] as? Int, let end = args["end"] as? Int,
              Self.validRange(start: start, end: end, size: size) else { throw invalid() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: end - start) ?? Data()
        guard data.count == end - start else { throw invalid() }
        result(FlutterStandardTypedData(bytes: data))
      }
    case "cacheDirectory" where channel == "save":
      let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("VoiceChatRecordings", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      result(root.path)
    case "begin" where channel == "save":
      guard !pickerOpen, let name = args["name"] as? String else { throw invalid() }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
      pickerOpen = true
      panel.begin { [weak self] response in
        guard let self = self else { return }
        self.pickerOpen = false
        guard response == .OK, let destination = panel.url else { result(nil); return }
        let scoped = destination.startAccessingSecurityScopedResource()
        var directory: URL?
        do {
          // A replacement directory is writable in the sandbox and on the destination volume.
          let staging = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: destination, create: true)
          directory = staging
          let temporary = staging.appendingPathComponent("download.tmp")
          guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else { throw self.invalid() }
          let handle = try FileHandle(forWritingTo: temporary)
          let id = UUID().uuidString
          self.saves[id] = Save(destination: destination, temporary: temporary, directory: staging, handle: handle, scoped: scoped)
          result(id)
        } catch {
          if let directory = directory { try? FileManager.default.removeItem(at: directory) }
          if scoped { destination.stopAccessingSecurityScopedResource() }
          result(FlutterError(code: "save", message: "Не удалось создать файл.", details: nil))
        }
      }
    case "write" where channel == "save":
      guard let id = args["id"] as? String, let save = saves[id],
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            bytes.data.count <= 4 * 1024 * 1024 else { throw invalid() }
      try save.handle.write(contentsOf: bytes.data)
      result(nil)
    case "finish" where channel == "save":
      guard let id = args["id"] as? String, let save = saves.removeValue(forKey: id) else { throw invalid() }
      defer {
        try? save.handle.close()
        try? FileManager.default.removeItem(at: save.directory)
        if save.scoped { save.destination.stopAccessingSecurityScopedResource() }
      }
      if args["success"] as? Bool == true {
        try save.handle.synchronize()
        try save.handle.close()
        if FileManager.default.fileExists(atPath: save.destination.path) {
          _ = try FileManager.default.replaceItemAt(save.destination, withItemAt: save.temporary)
        } else { try FileManager.default.moveItem(at: save.temporary, to: save.destination) }
      }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// Finder drops use the same scoped handles, range checks and release as NSOpenPanel.
  func select(_ urls: [URL]) throws -> [[String: Any]] {
    var added: [String] = []
    do {
      guard !urls.isEmpty, urls.count <= 84 else { throw invalid() }
      return try urls.map { url in
        guard url.isFileURL else { throw invalid() }
        let id = UUID().uuidString
        let scoped = url.startAccessingSecurityScopedResource()
        selections[id] = Selection(url: url, scoped: scoped)
        added.append(id)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw invalid() }
        return ["uri": id, "name": url.lastPathComponent, "size": size,
                "mime": values.contentType?.preferredMIMEType ?? "application/octet-stream"]
      }
    } catch {
      for id in added { release(id) }
      throw error
    }
  }

  static func validRange(start: Int, end: Int, size: UInt64) -> Bool {
    start >= 0 && end > start && end - start <= 4 * 1024 * 1024 && UInt64(end) <= size
  }
  private func invalid() -> NSError { NSError(domain: "VoiceChatFiles", code: 1) }
  func release(_ id: String) {
    if let selected = selections.removeValue(forKey: id), selected.scoped {
      selected.url.stopAccessingSecurityScopedResource()
    }
  }
  deinit {
    for id in Array(selections.keys) { release(id) }
    for save in saves.values {
      try? save.handle.close()
      try? FileManager.default.removeItem(at: save.directory)
      if save.scoped { save.destination.stopAccessingSecurityScopedResource() }
    }
  }
}
