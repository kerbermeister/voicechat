import XCTest
@testable import VoiceChat

class RunnerTests: XCTestCase {
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
