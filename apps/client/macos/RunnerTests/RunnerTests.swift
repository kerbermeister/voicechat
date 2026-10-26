import XCTest
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
    XCTAssertTrue(PlatformFiles.validRange(start: 0, end: 1, size: 1))
    XCTAssertTrue(PlatformFiles.validRange(start: 2, end: 4, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: -1, end: 1, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 4, end: 4, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 3, end: 5, size: 4))
    XCTAssertFalse(PlatformFiles.validRange(start: 0, end: 4 * 1024 * 1024 + 1, size: 10 * 1024 * 1024))
    XCTAssertFalse(PlatformFiles.validRange(start: Int.min, end: Int.max, size: UInt64.max))
  }
}
