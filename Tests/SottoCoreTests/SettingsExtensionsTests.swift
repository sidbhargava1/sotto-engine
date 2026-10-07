// ADR §1: host settings ride in the engine's Settings without the engine knowing their type.
import XCTest
@testable import SottoCore

final class SettingsExtensionsTests: XCTestCase {
    private enum Flag: SettingsKey { static let defaultValue = false }
    private enum Names: SettingsKey { static let defaultValue: [String] = ["a"] }

    func test_unsetReadsTheDefault() {
        XCTAssertEqual(Settings().extensions[Flag.self], false)
        XCTAssertEqual(Settings().extensions[Names.self], ["a"])
    }

    func test_valuesAreKeyedByType() {
        var s = Settings()
        s.extensions[Flag.self] = true
        s.extensions[Names.self] = ["b", "c"]
        XCTAssertEqual(s.extensions[Flag.self], true)
        XCTAssertEqual(s.extensions[Names.self], ["b", "c"])
    }

    func test_equalityComparesValues() {
        var a = Settings(), b = Settings()
        a.extensions[Flag.self] = true
        XCTAssertNotEqual(a, b)
        b.extensions[Flag.self] = true
        XCTAssertEqual(a, b)
        b.extensions[Names.self] = ["z"]
        XCTAssertNotEqual(a, b)
    }

    func test_settingTheDefaultEqualsNeverSetting() {
        var s = Settings()
        s.extensions[Flag.self] = true
        s.extensions[Flag.self] = false
        XCTAssertEqual(s, Settings())
    }
}
