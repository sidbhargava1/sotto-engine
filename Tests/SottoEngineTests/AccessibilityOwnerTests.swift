// Own-process AX hazard (0.2.1 crash): calls on Sotto's own elements run AppKit in-process and
// must be on main; other apps' elements stay off main. The write itself needs AX trust, so it's
// a manual step (docs/injection-matrix.md "Sotto's own window").
import ApplicationServices
import XCTest
@testable import SottoEngine

final class AccessibilityOwnerTests: XCTestCase {
    func test_ownElement_runsOnMain() async {
        let own = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(AccessibilityFocus.isOwn(own))
        let onMain = await Task.detached { await AccessibilityFocus.onOwner(of: own) { _ in Thread.isMainThread } }.value
        XCTAssertTrue(onMain, "AppKit asserts the main queue for in-process AX setters")
    }

    func test_otherProcessElement_staysOffMain() async {
        let other = AXUIElementCreateApplication(1)  // launchd
        XCTAssertFalse(AccessibilityFocus.isOwn(other))
        let onMain = await Task.detached { await AccessibilityFocus.onOwner(of: other) { _ in Thread.isMainThread } }.value
        XCTAssertFalse(onMain, "blocking IPC must not stall the UI")
    }

    func test_noElement_runsInPlace() async {
        let onMain = await Task.detached { await AccessibilityFocus.onOwner(of: nil) { _ in Thread.isMainThread } }.value
        XCTAssertFalse(onMain)
    }
}
