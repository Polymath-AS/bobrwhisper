import AppKit
import ApplicationServices
import Foundation

/// Context captured before BobrWhisper's overlay appears. Raw field text is
/// held only for the lifetime of one recording and is never logged.
struct FocusedContext {
    let bundleID: String
    let windowTitle: String
    let textBeforeCursor: String
    let textAfterCursor: String
    let selectedText: String
    let isSecure: Bool
}

final class FocusedFieldSession {
    enum Strategy: Equatable {
        case managedRange
        case finalPaste
        case overlayOnly
    }

    let context: FocusedContext
    private(set) var strategy: Strategy

    private let application: NSRunningApplication?
    private let applicationElement: AXUIElement?
    private let field: AXUIElement?
    private var expectedValue: String?
    private var managedRange: CFRange?
    private var expectedSelection: CFRange?
    private var managedText: String
    private var detached = false

    static func capture(insertionEnabled: Bool) -> FocusedFieldSession {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else {
            return FocusedFieldSession.empty()
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.12)
        let contextDeadline = CFAbsoluteTimeGetCurrent() + 0.18
        guard let field: AXUIElement = copyAttribute(appElement, kAXFocusedUIElementAttribute) else {
            return FocusedFieldSession.empty(bundleID: application.bundleIdentifier ?? "")
        }

        let secure = isSecureField(field)
        if secure {
            NSLog("BobrWhisper insertion strategy: %@", Strategy.overlayOnly.diagnosticName)
            return FocusedFieldSession(
                context: FocusedContext(
                    bundleID: application.bundleIdentifier ?? "",
                    windowTitle: "",
                    textBeforeCursor: "",
                    textAfterCursor: "",
                    selectedText: "",
                    isSecure: true
                ),
                strategy: .overlayOnly,
                application: nil,
                applicationElement: nil,
                field: nil,
                expectedValue: nil,
                managedRange: nil,
                expectedSelection: nil,
                managedText: ""
            )
        }

        let capturedValue: String? = copyAttribute(field, kAXValueAttribute)
        let value = capturedValue ?? ""
        let selectedRange = copyRange(field, kAXSelectedTextRangeAttribute)
        let skipAdditionalContext = CFAbsoluteTimeGetCurrent() >= contextDeadline
        let selectedText: String = skipAdditionalContext ? "" : (copyAttribute(field, kAXSelectedTextAttribute) ?? "")
        let window: AXUIElement? = skipAdditionalContext ? nil : copyAttribute(appElement, kAXFocusedWindowAttribute)
        let title: String = window.flatMap { copyAttribute($0, kAXTitleAttribute) } ?? ""
        let retrievalTimedOut = skipAdditionalContext || CFAbsoluteTimeGetCurrent() >= contextDeadline

        let boundedTitle = title.utf8Prefix(maxBytes: 256)
        var before = ""
        var after = ""
        if !retrievalTimedOut, let range = selectedRange {
            let nsValue = value as NSString
            let start = max(0, min(range.location, nsValue.length))
            let end = max(start, min(range.location + range.length, nsValue.length))
            before = nsValue.substring(with: NSRange(location: 0, length: start)).utf8Suffix(maxBytes: 1_024)
            after = nsValue.substring(from: end).utf8Prefix(maxBytes: 512)
        }

        let supportsManagedRange = insertionEnabled && capturedValue != nil
            && isSettable(field, kAXSelectedTextRangeAttribute)
            && isSettable(field, kAXSelectedTextAttribute) && selectedRange != nil
        let strategy = chooseStrategy(
            insertionEnabled: insertionEnabled,
            secure: secure,
            supportsManagedRange: supportsManagedRange
        )

        NSLog("BobrWhisper insertion strategy: %@", strategy.diagnosticName)
        return FocusedFieldSession(
            context: FocusedContext(
                bundleID: retrievalTimedOut ? "" : (application.bundleIdentifier ?? ""),
                windowTitle: retrievalTimedOut ? "" : boundedTitle,
                textBeforeCursor: retrievalTimedOut ? "" : before,
                textAfterCursor: retrievalTimedOut ? "" : after,
                selectedText: retrievalTimedOut ? "" : selectedText.utf8Prefix(maxBytes: 512),
                isSecure: false
            ),
            strategy: strategy,
            application: application,
            applicationElement: appElement,
            field: field,
            expectedValue: capturedValue,
            managedRange: selectedRange,
            expectedSelection: selectedRange,
            managedText: selectedText
        )
    }

    static func chooseStrategy(insertionEnabled: Bool, secure: Bool, supportsManagedRange: Bool) -> Strategy {
        if !insertionEnabled || secure { return .overlayOnly }
        return supportsManagedRange ? .managedRange : .finalPaste
    }

    private static func empty(bundleID: String = "") -> FocusedFieldSession {
        FocusedFieldSession(
            context: FocusedContext(
                bundleID: bundleID,
                windowTitle: "",
                textBeforeCursor: "",
                textAfterCursor: "",
                selectedText: "",
                isSecure: false
            ),
            strategy: .overlayOnly,
            application: nil,
            applicationElement: nil,
            field: nil,
            expectedValue: nil,
            managedRange: nil,
            expectedSelection: nil,
            managedText: ""
        )
    }

    private init(
        context: FocusedContext,
        strategy: Strategy,
        application: NSRunningApplication?,
        applicationElement: AXUIElement?,
        field: AXUIElement?,
        expectedValue: String?,
        managedRange: CFRange?,
        expectedSelection: CFRange?,
        managedText: String
    ) {
        self.context = context
        self.strategy = strategy
        self.application = application
        self.applicationElement = applicationElement
        self.field = field
        self.expectedValue = expectedValue
        self.managedRange = managedRange
        self.expectedSelection = expectedSelection
        self.managedText = managedText
    }

    /// Replace only text previously owned by this session. Any focus,
    /// selection, process, or content mismatch permanently detaches it.
    func apply(text: String, isFinal: Bool) {
        guard !detached else { return }
        switch strategy {
        case .managedRange:
            guard replaceManagedRange(with: text) else {
                detach(reason: "managed-range ownership changed")
                return
            }
        case .finalPaste:
            guard isFinal else { return }
            guard stillOwnsOriginalFocus() else {
                detach(reason: "original field lost focus")
                return
            }
            guard stillMatchesOriginalField() else {
                detach(reason: "original field contents or selection changed")
                return
            }
            pasteOncePreservingClipboard(text)
            detach(reason: "final paste completed")
        case .overlayOnly:
            return
        }
    }

    func detach(reason: String? = nil) {
        if let reason { NSLog("BobrWhisper insertion detached: %@", reason) }
        detached = true
        strategy = .overlayOnly
    }

    private func replaceManagedRange(with replacement: String) -> Bool {
        guard let field, let range = managedRange, let expectedSelection else { return false }
        guard stillOwnsOriginalFocus(), rangesEqual(copyRange(field, kAXSelectedTextRangeAttribute), expectedSelection) else {
            return false
        }
        guard let current: String = copyAttribute(field, kAXValueAttribute),
              current == expectedValue,
              substring(current, range: range) == managedText else {
            return false
        }

        guard setRange(field, kAXSelectedTextRangeAttribute, range),
              AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }

        let replacementLength = (replacement as NSString).length
        expectedValue = (current as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
        managedRange = CFRange(location: range.location, length: replacementLength)
        let caret = CFRange(location: range.location + replacementLength, length: 0)
        guard setRange(field, kAXSelectedTextRangeAttribute, caret) else { return false }
        self.expectedSelection = caret
        managedText = replacement
        return true
    }

    private func stillOwnsOriginalFocus() -> Bool {
        guard let application, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let applicationElement, let field,
              let focused: AXUIElement = copyAttribute(applicationElement, kAXFocusedUIElementAttribute) else {
            return false
        }
        return CFEqual(focused, field)
    }

    private func stillMatchesOriginalField() -> Bool {
        guard let field else { return false }
        let currentValue: String? = copyAttribute(field, kAXValueAttribute)
        let currentSelection = copyRange(field, kAXSelectedTextRangeAttribute)
        return insertionStateMatches(
            expectedValue: expectedValue,
            currentValue: currentValue,
            expectedSelection: expectedSelection,
            currentSelection: currentSelection
        )
    }

    private func pasteOncePreservingClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let bobrChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount == bobrChangeCount,
                  pasteboard.string(forType: .string) == text else { return }
            snapshot.restore(to: pasteboard)
        }
    }
}

private extension FocusedFieldSession.Strategy {
    var diagnosticName: String {
        switch self {
        case .managedRange: return "managed-range"
        case .finalPaste: return "final-paste"
        case .overlayOnly: return "overlay-only"
        }
    }
}

struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

private func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
    guard let value: AXValue = copyAttribute(element, attribute) else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value, .cfRange, &range) else { return nil }
    return range
}

private func setRange(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> Bool {
    var mutableRange = range
    guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
    return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
}

private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
}

private func isSecureField(_ field: AXUIElement) -> Bool {
    let subrole: String = copyAttribute(field, kAXSubroleAttribute) ?? ""
    if subrole == "AXSecureTextField" { return true }
    let protected: Bool = copyAttribute(field, "AXProtectedContent") ?? false
    return protected
}

func rangesEqual(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return lhs.location == rhs.location && lhs.length == rhs.length
}

func insertionStateMatches(
    expectedValue: String?,
    currentValue: String?,
    expectedSelection: CFRange?,
    currentSelection: CFRange?
) -> Bool {
    if let expectedValue, currentValue != expectedValue { return false }
    if let expectedSelection, !rangesEqual(currentSelection, expectedSelection) { return false }
    return true
}

func substring(_ value: String, range: CFRange) -> String? {
    let nsValue = value as NSString
    guard range.location >= 0, range.length >= 0, range.location + range.length <= nsValue.length else { return nil }
    return nsValue.substring(with: NSRange(location: range.location, length: range.length))
}

private extension String {
    func utf8Prefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var result = ""
        var count = 0
        for character in self {
            let bytes = String(character).utf8.count
            if count + bytes > maxBytes { break }
            result.append(character)
            count += bytes
        }
        return result
    }

    func utf8Suffix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var result = ""
        var count = 0
        for character in reversed() {
            let fragment = String(character)
            let bytes = fragment.utf8.count
            if count + bytes > maxBytes { break }
            result.insert(contentsOf: fragment, at: result.startIndex)
            count += bytes
        }
        return result
    }
}
