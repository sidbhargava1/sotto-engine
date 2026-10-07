// --inject back into the app `sotto` was launched from: always terminal-class, so line breaks
// become spaces even in integrated terminals the default list doesn't know.
import SottoCore
@testable import SottoCLI
import XCTest

final class LaunchingAppPolicyTests: XCTestCase {
    private func release(_ bundleID: String?, owner: String? = nil) -> TargetContext {
        TargetContext(bundleID: bundleID, isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true, focusOwnerBundleID: owner)
    }

    func test_launchingAppIsTerminalClass() {
        let policy = LaunchingAppPolicy(launchApp: "com.microsoft.VSCode")
        let (context, moved) = policy.resolveTarget(pressApp: nil, release: release("com.microsoft.VSCode"))
        XCTAssertTrue(context.isTerminalClass)
        XCTAssertFalse(moved)
        XCTAssertEqual(policy.strategy(for: context), .unicodeType)
        XCTAssertEqual(context.elementToken, AXElementToken(1))
    }

    func test_focusOwnerMatchCounts() {
        let policy = LaunchingAppPolicy(launchApp: "dev.zed.Zed")
        XCTAssertTrue(policy.resolveTarget(pressApp: nil, release: release("com.other", owner: "dev.zed.Zed")).context.isTerminalClass)
    }

    func test_otherAppsKeepTheDefault() {
        let policy = LaunchingAppPolicy(launchApp: "com.microsoft.VSCode")
        let (context, _) = policy.resolveTarget(pressApp: nil, release: release("com.apple.TextEdit"))
        XCTAssertFalse(context.isTerminalClass)
        XCTAssertEqual(policy.strategy(for: context), .axSelectedText)
        XCTAssertFalse(LaunchingAppPolicy(launchApp: nil).resolveTarget(pressApp: nil, release: release("com.apple.TextEdit")).context.isTerminalClass)
    }
}
