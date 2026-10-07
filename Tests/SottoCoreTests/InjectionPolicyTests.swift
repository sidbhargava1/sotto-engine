// IP-xx ids per docs/phase1-test-scenarios.md.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class InjectionPolicyTests: XCTestCase {
    private let policy = DefaultInjectionPolicy(hostBundleID: "com.example.host")

    func test_IP01_terminalClassStartsAtUnicode() {
        let context = makeTestContext(bundleID: "com.mitchellh.ghostty", isTerminalClass: true)
        XCTAssertEqual(policy.strategy(for: context), .unicodeType)
    }

    func test_IP02_unknownBundleIDFallsBackToAXDefault() {
        let context = makeTestContext(bundleID: "com.unknown.app", isTerminalClass: false)
        XCTAssertEqual(policy.strategy(for: context), .axSelectedText)
    }

    func test_IP03_perAppOverrideWinsOverDefault() {
        let context = makeTestContext(bundleID: "com.slack.slack", isTerminalClass: false)
        let strategy = policy.strategy(for: context, overrides: ["com.slack.slack": .paste])
        XCTAssertEqual(strategy, .paste)
    }

    func test_IP04_policyNeverProbesRuntimeAXSupport() {
        // Policy only ever consults static info (terminal-class + overrides) — a non-terminal
        // target with no override always gets .axSelectedText, regardless of whether AX would
        // actually work at runtime. Runtime failure detection is the injector's job.
        let context = makeTestContext(bundleID: "com.electron.app", isTerminalClass: false)
        XCTAssertEqual(policy.strategy(for: context), .axSelectedText)
        XCTAssertEqual(Self.standardChain.fallback(after: .axSelectedText), .paste)
    }

    func test_IP06_trimLineEndsDropsHardBreakSpacesButKeepsNewlines() {
        XCTAssertEqual(InjectionText.trimLineEnds("Notes:  \n1. A \t\n2. B  "), "Notes:\n1. A\n2. B  ")
        XCTAssertEqual(InjectionText.trimLineEnds("one line  "), "one line  ", "only spaces before a break go")
        XCTAssertEqual(InjectionText.trimLineEnds("a\n\nb"), "a\n\nb")
    }

    func test_IP05_doubleNewlineDegradesToSingleSpace() {
        let sanitized = InjectionText.sanitizeForTerminal("first line\n\nsecond line")
        XCTAssertEqual(sanitized, "first line second line")
        XCTAssertFalse(sanitized.contains("\n"))
    }

    func test_fallbackChainEndsAtUnicode() {
        XCTAssertEqual(Self.standardChain.fallback(after: .paste), .unicodeType)
        XCTAssertNil(Self.standardChain.fallback(after: .unicodeType))
    }

    func test_TC05_hotkeyPanelIsNotAFocusMove() {
        let release = TargetContext(bundleID: "com.apple.Safari", isTerminalClass: false, elementToken: AXElementToken(UUID()), accessibilityGranted: true, focusOwnerBundleID: "com.googlecode.iterm2")
        let (context, moved) = policy.resolveTarget(pressApp: "com.googlecode.iterm2", release: release)
        XCTAssertFalse(moved, "frontmost != focused app is the panel case, not a move")
        XCTAssertEqual(context.bundleID, "com.googlecode.iterm2")
        XCTAssertTrue(context.isTerminalClass)
        XCTAssertEqual(context.elementToken, release.elementToken)
        XCTAssertEqual(policy.strategy(for: context), .unicodeType)
    }

    func test_TC06_unknownReleaseOwnerFallsBackToFrontmostForTheMoveCheck() {
        // Pressed in TextEdit, switched to Chrome while speaking, Chrome's focus unreadable.
        let release = TargetContext(bundleID: "com.google.Chrome", isTerminalClass: false, elementToken: nil, accessibilityGranted: true)
        let (_, moved) = policy.resolveTarget(pressApp: "com.apple.TextEdit", release: release)
        XCTAssertTrue(moved, "else TextEdit's text pastes into Chrome")
        let (same, stayed) = policy.resolveTarget(pressApp: "com.google.Chrome", release: release)
        XCTAssertFalse(stayed)
        XCTAssertEqual(same.bundleID, "com.google.Chrome")
        let (_, unknownPress) = policy.resolveTarget(pressApp: nil, release: release)
        XCTAssertFalse(unknownPress, "unknown press app is never a move")
        let hostFrontmost = TargetContext(bundleID: "com.example.host", isTerminalClass: false, elementToken: nil, accessibilityGranted: true)
        let (_, hostMoved) = policy.resolveTarget(pressApp: "com.apple.TextEdit", release: hostFrontmost)
        XCTAssertFalse(hostMoved, "the host's own window frontmost at release is not a move")
    }

    private static let standardChain = InjectorChain(ax: RecordingInjector(), paste: RecordingInjector(), unicode: RecordingInjector())
}
