import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class RawBackendTests: XCTestCase {
    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var result = ""
        for try await chunk in stream { result += chunk }
        return result
    }

    func test_collapsesWhitespaceAndTrims() async throws {
        let request = CleanupRequest(rawTranscript: "  so   um   hello   there  ", dictionary: [], targetContext: makeTestContext())
        let result = try await collect(RawBackend().clean(request))
        XCTAssertEqual(result, "so um hello there")
    }

    func test_emptyInputProducesEmptyOutput() async throws {
        let request = CleanupRequest(rawTranscript: "   ", dictionary: [], targetContext: makeTestContext())
        let result = try await collect(RawBackend().clean(request))
        XCTAssertEqual(result, "")
    }
}
