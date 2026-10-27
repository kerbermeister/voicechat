import XCTest
import FlutterMacOS
@testable import VoiceChat

class RunnerTests: XCTestCase {
  func testWindowExposesAppKitDragSelectors() {
    let window = MainFlutterWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    XCTAssertTrue(window.responds(to: #selector(NSDraggingDestination.draggingEntered(_:))))
    XCTAssertTrue(window.responds(to: #selector(NSDraggingDestination.draggingUpdated(_:))))
    XCTAssertTrue(window.responds(to: #selector(NSDraggingDestination.performDragOperation(_:))))
  }
  func testDropRegionRejectsInvalidGeometry() {
    XCTAssertNil(MainFlutterWindow.dropRect(nil))
    XCTAssertNil(MainFlutterWindow.dropRect(["x": 0.0, "y": 0.0, "width": -1.0, "height": 20.0]))
    XCTAssertNil(MainFlutterWindow.dropRect(["x": Double.nan, "y": 0.0, "width": 20.0, "height": 20.0]))
    XCTAssertEqual(MainFlutterWindow.dropRect(["x": 10.0, "y": 20.0, "width": 30.0, "height": 40.0]),
                   NSRect(x: 10, y: 20, width: 30, height: 40))
  }
  func testFileRangesCannotEscapeSelectionOrExhaustMemory() {
    XCTAssertTrue(PlatformFiles.validRange(start: 4_999_999_999, end: 5_000_000_000, size: 5_000_000_000))
    XCTAssertFalse(PlatformFiles.validRange(start: 5_000_000_000, end: 5_000_000_001, size: 5_000_000_000))
    XCTAssertTrue(PlatformFiles.validRange(start: 0, end: 1, size: 1))
    XCTAssertTrue(PlatformFiles.validRange(start: 2, end: 4, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: -1, end: 1, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 4, end: 4, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 3, end: 5, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 0, end: 4 * 1024 * 1024 + 1, size: 10 * 1024 * 1024))
    XCTAssertFalse(PlatformFiles.validRange(start: Int.min, end: Int.max, size: UInt64.max))
  }
}


private final class ClipboardMessenger: NSObject, FlutterBinaryMessenger {
  var handlers: [String: FlutterBinaryMessageHandler] = [:]
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    return Int64(handlers.count)
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  func clipboard(_ method: String, _ args: [String: Any]) throws -> Any? {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    var reply: Data?
    handlers["voicechat/clipboard"]?(codec.encode(FlutterMethodCall(methodName: method, arguments: args))) { reply = $0 }
    return try codec.decodeEnvelope(XCTUnwrap(reply))
  }
}

extension RunnerTests {
  func testClipboardCommitsExactFileAndRejectsTruncation() throws {
    let board = NSPasteboard.general
    let saved: [NSPasteboardItem] = try (board.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          guard data.count <= 10 * 1024 * 1024 else { throw XCTSkip("Large user clipboard; leave unchanged") }
          copy.setData(data, forType: type)
        }
      }
      return copy
    }
    var ourChange = -1
    defer {
      if board.changeCount == ourChange { board.clearContents(); board.writeObjects(saved) }
    }
    let messenger = ClipboardMessenger()
    let files = PlatformFiles(messenger: messenger)
    try withExtendedLifetime(files) {
      let id = try XCTUnwrap(messenger.clipboard("begin", ["name": "clipboard-test.txt", "size": 3, "mime": "text/plain"]) as? String)
      XCTAssertNotNil(try messenger.clipboard("commit", ["ids": [id]]) as? FlutterError)
      _ = try messenger.clipboard("write", ["id": id, "bytes": FlutterStandardTypedData(bytes: Data([1, 2, 3]))])
      XCTAssertNotNil(try messenger.clipboard("write", ["id": id, "bytes": FlutterStandardTypedData(bytes: Data([4]))]) as? FlutterError)
      _ = try messenger.clipboard("commit", ["ids": [id]])
      ourChange = board.changeCount
      let url = try XCTUnwrap(board.string(forType: .fileURL).flatMap(URL.init(string:)))
      XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
      try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }
}
