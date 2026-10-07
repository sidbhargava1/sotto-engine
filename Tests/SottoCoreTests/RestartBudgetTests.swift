// Configuration-change restart budget (SPEC §5 "Restart budget"): a flapping HFP route gives up
// after the budget; a healthy route switch never comes close.
import XCTest
@testable import SottoCore

final class RestartBudgetTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    /// One restart per change, each finishing 50 ms later; returns the decisions.
    private func storm(_ budget: inout RestartBudget, device: String? = "pods", every ms: Int, count: Int, from start: Int = 0) -> [RestartBudget.Decision] {
        (0..<count).map { i in
            let now = start + i * ms
            let decision = budget.configurationChanged(device: device, at: at(now))
            if decision == .restart { budget.restartFinished(at: at(now + 50)) }
            return decision
        }
    }

    func test_healthyRouteSwitch_restartsEveryTime() {
        var budget = RestartBudget()
        // HFP switch on open, then another a few seconds later: well inside the budget.
        XCTAssertEqual(storm(&budget, every: 3_000, count: 4), Array(repeating: .restart, count: 4))
    }

    func test_fieldStorm_givesUpOnTheFifth() {
        var budget = RestartBudget()
        let decisions = storm(&budget, every: 340, count: 5)  // the work Mac's cadence
        XCTAssertEqual(decisions, [.restart, .restart, .restart, .restart, .giveUp])
    }

    func test_windowSlides_oldRestartsDoNotCount() {
        var budget = RestartBudget()
        _ = storm(&budget, every: 1_000, count: 4)
        // 4 restarts at 0..3 s; at 10.5 s the first two have left the window.
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(10_500)), .restart)
        budget.restartFinished(at: at(10_550))
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(11_500)), .restart)
    }

    func test_echoWithinCoalesceWindow_isNotARestart() {
        var budget = RestartBudget()
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(0)), .restart)
        budget.restartFinished(at: at(300))
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(340)), .coalesce(after: .milliseconds(60)))
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(380)), .coalesce(after: .milliseconds(20)))
        XCTAssertEqual(budget.count, 1, "coalesced changes never spend budget")
        XCTAssertEqual(budget.configurationChanged(device: "pods", at: at(400)), .restart)
    }

    func test_deviceChange_startsAFreshBudget() {
        var budget = RestartBudget()
        _ = storm(&budget, every: 340, count: 4)
        XCTAssertEqual(budget.configurationChanged(device: "mac", at: at(1_500)), .restart)
        XCTAssertEqual(budget.count, 1)
    }

    func test_failedRestarts_unknownDevice_stillCount() {
        var budget = RestartBudget()
        // The field log: a failed restart leaves no device, then the storm resumes on the same one.
        let devices: [String?] = ["pods", nil, "pods", nil, "pods"]
        let decisions = devices.enumerated().map { i, device in
            let decision = budget.configurationChanged(device: device, at: at(i * 340))
            if decision == .restart { budget.restartFinished(at: at(i * 340 + 50)) }
            return decision
        }
        XCTAssertEqual(decisions.last, .giveUp)
    }

    func test_reset_clearsCount() {
        var budget = RestartBudget()
        _ = storm(&budget, every: 340, count: 4)
        budget.reset()
        XCTAssertEqual(storm(&budget, every: 340, count: 4, from: 2_000), Array(repeating: .restart, count: 4))
    }

    func test_afterGivingUp_theFallbackStartsClean() {
        var budget = RestartBudget()
        XCTAssertEqual(storm(&budget, every: 340, count: 5).last, .giveUp)
        XCTAssertEqual(budget.count, 0)
        XCTAssertEqual(budget.configurationChanged(device: "mac", at: at(2_000)), .restart)
    }
}
