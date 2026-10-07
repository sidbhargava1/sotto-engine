// Settings mic picker: absent or failing chosen devices fall back without losing the choice (ui-spec §4).
import XCTest
@testable import SottoCore

final class InputSelectionTests: XCTestCase {
    func test_systemDefault() {
        let s = InputSelection()
        XCTAssertEqual(s.attempts(available: ["mac"]), [nil])
        XCTAssertFalse(s.fellBack(available: ["mac"]))
    }

    func test_presentChosenDevice_triedFirstThenDefault() {
        let s = InputSelection(preferred: "pods")
        XCTAssertEqual(s.attempts(available: ["mac", "pods"]), ["pods", nil])
        XCTAssertEqual(s.expected(available: ["mac", "pods"]), "pods")
        XCTAssertFalse(s.fellBack(available: ["mac", "pods"]))
    }

    func test_absentChosenDevice_fallsBackAndKeepsChoice() {
        let s = InputSelection(preferred: "pods")
        XCTAssertEqual(s.attempts(available: ["mac"]), [nil])
        XCTAssertTrue(s.fellBack(available: ["mac"]))
        XCTAssertEqual(s.preferred, "pods")
        XCTAssertFalse(s.fellBack(available: ["mac", "pods"]), "applies again when it returns")
    }

    func test_chosenDeviceFailsToStart_runtimeFallbackUntilItStarts() {
        var s = InputSelection(preferred: "pods")
        let available = ["mac", "pods"]
        s.failed(on: "pods")
        s.started(on: nil)
        XCTAssertTrue(s.fellBack(available: available), "the footnote must show on a runtime fallback")
        XCTAssertNil(s.expected(available: available))
        XCTAssertEqual(s.attempts(available: available), ["pods", nil], "the next start retries the choice")
        XCTAssertEqual(s.preferred, "pods")
        s.started(on: "pods")
        XCTAssertFalse(s.fellBack(available: available))
    }

    func test_defaultFailing_isNotAFallback() {
        var s = InputSelection()
        s.failed(on: nil)
        XCTAssertFalse(s.fellBack(available: ["mac"]))
    }

    func test_choosingAgain_clearsRuntimeFallback() {
        var s = InputSelection(preferred: "pods")
        s.failed(on: "pods")
        s.choose("usb")
        XCTAssertFalse(s.fellBack(available: ["usb"]))
        s.choose(nil)
        XCTAssertFalse(s.fellBack(available: []))
    }
}

/// RestartBudget give-up: the device that kept reconfiguring is skipped for the built-in mic.
final class InputSelectionUnstableTests: XCTestCase {
    private let available = ["mac", "pods"]

    func test_nothingUnstable_extraArgumentsChangeNothing() {
        let s = InputSelection()
        XCTAssertEqual(s.attempts(available: available, defaultUID: "pods", fallbacks: ["mac"]), [nil])
        XCTAssertFalse(s.fellBack(available: available, defaultUID: "pods", fallbacks: ["mac"]))
        XCTAssertNil(s.unstableStandIn(available: available, defaultUID: "pods", fallbacks: ["mac"]))
    }

    func test_unstableSystemDefault_fallsToBuiltIn() {
        var s = InputSelection()
        s.markUnstable("pods")
        XCTAssertEqual(s.attempts(available: available, defaultUID: "pods", fallbacks: ["mac"]), ["mac"])
        XCTAssertEqual(s.expected(available: available, defaultUID: "pods", fallbacks: ["mac"]), "mac")
        XCTAssertTrue(s.fellBack(available: available, defaultUID: "pods", fallbacks: ["mac"]), "Settings shows the fallback state")
        XCTAssertEqual(s.unstableStandIn(available: available, defaultUID: "pods", fallbacks: ["mac"]), "pods")
    }

    func test_unstableChosenDevice_fallsToBuiltInThenDefault() {
        var s = InputSelection(preferred: "pods")
        s.markUnstable("pods")
        XCTAssertEqual(s.attempts(available: available + ["usb"], defaultUID: "usb", fallbacks: ["mac"]), ["mac", nil])
        XCTAssertEqual(s.preferred, "pods", "the stored choice is kept")
    }

    func test_unstableDeviceNotTheTarget_isIgnored() {
        var s = InputSelection()
        s.markUnstable("pods")
        XCTAssertEqual(s.attempts(available: available, defaultUID: "mac", fallbacks: ["mac"]), [nil])
        XCTAssertFalse(s.fellBack(available: available, defaultUID: "mac", fallbacks: ["mac"]))
    }

    func test_noStableDeviceLeft_isEmpty() {
        var s = InputSelection()
        s.markUnstable("pods")
        s.markUnstable("mac")
        XCTAssertEqual(s.attempts(available: available, defaultUID: "pods", fallbacks: ["mac", "pods"]), [])
        XCTAssertNil(s.expected(available: available, defaultUID: "pods", fallbacks: ["mac"]))
    }

    func test_pickerChange_forgetsUnstable() {
        var s = InputSelection()
        s.markUnstable("pods")
        s.choose(nil)
        XCTAssertEqual(s.attempts(available: available, defaultUID: "pods", fallbacks: ["mac"]), [nil])
    }

    func test_disconnect_forgetsUnstable_reconnectGetsAFreshChance() {
        var s = InputSelection()
        s.markUnstable("pods")
        s.devicesChanged(available: available)
        XCTAssertEqual(s.unstable, ["pods"], "a list change that keeps it doesn't")
        s.devicesChanged(available: ["mac"])
        XCTAssertEqual(s.unstable, [])
    }
}
