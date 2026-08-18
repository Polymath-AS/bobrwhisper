import AppKit
import XCTest
@testable import BobrWhisper

final class ContextInsertionTests: XCTestCase {
    func testStrategyRejectsSecureAndDisabledFields() {
        XCTAssertEqual(
            FocusedFieldSession.chooseStrategy(insertionEnabled: true, secure: true, supportsManagedRange: true),
            .overlayOnly
        )
        XCTAssertEqual(
            FocusedFieldSession.chooseStrategy(insertionEnabled: false, secure: false, supportsManagedRange: true),
            .overlayOnly
        )
    }

    func testUnsupportedFieldUsesOneShotFallback() {
        XCTAssertEqual(
            FocusedFieldSession.chooseStrategy(insertionEnabled: true, secure: false, supportsManagedRange: false),
            .finalPaste
        )
        XCTAssertTrue(insertionStateMatches(
            expectedValue: nil,
            currentValue: nil,
            expectedSelection: nil,
            currentSelection: nil
        ))
    }

    func testFallbackDetectsAvailableFieldChanges() {
        XCTAssertFalse(insertionStateMatches(
            expectedValue: "before",
            currentValue: "user edit",
            expectedSelection: nil,
            currentSelection: nil
        ))
        XCTAssertFalse(insertionStateMatches(
            expectedValue: nil,
            currentValue: nil,
            expectedSelection: CFRange(location: 2, length: 0),
            currentSelection: CFRange(location: 3, length: 0)
        ))
    }

    func testUnicodeRangesUseAccessibilityUTF16Offsets() {
        let value = "before 🙂 after"
        let nsValue = value as NSString
        let emojiRange = nsValue.range(of: "🙂")
        XCTAssertEqual(
            substring(value, range: CFRange(location: emojiRange.location, length: emojiRange.length)),
            "🙂"
        )
        XCTAssertNil(substring(value, range: CFRange(location: nsValue.length + 1, length: 1)))
    }

    func testRangeComparisonDetectsCursorMovement() {
        XCTAssertTrue(rangesEqual(CFRange(location: 4, length: 0), CFRange(location: 4, length: 0)))
        XCTAssertFalse(rangesEqual(CFRange(location: 4, length: 0), CFRange(location: 5, length: 0)))
    }

    func testPasteboardSnapshotRestoresEveryItemType() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BobrWhisperTests-\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data([0x01, 0x02, 0x03]), forType: .init("com.bobrwhisper.test-data"))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
        XCTAssertEqual(pasteboard.data(forType: .init("com.bobrwhisper.test-data")), Data([0x01, 0x02, 0x03]))
    }
}
