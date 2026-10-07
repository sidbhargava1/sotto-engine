// ADR §3: the injector chain is an ordered list a host can reorder or trim, and the policy that
// picks the first strategy is swappable. Defaults are covered by DictationSessionTests.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class InjectorChainTests: SessionTestCase {
    private struct AlwaysPaste: InjectionPolicy {
        func strategy(for context: TargetContext, overrides: [String: InjectionStrategy]) -> InjectionStrategy { .paste }
        func resolveTarget(pressApp: String?, release: TargetContext) -> (context: TargetContext, focusMoved: Bool) {
            (release, false)
        }
    }

    func test_customOrderSetsTheFallback() async {
        // AX fails (every chunk); this host put unicode before paste, so unicode takes the text.
        let h = makeHarness(axOutcomes: Array(repeating: .failed, count: 8), chain: { ax, paste, unicode in
            InjectorChain([(.axSelectedText, ax), (.unicodeType, unicode), (.paste, paste)])
        })
        await runUtterance(h)
        let unicode = await h.unicode.injectedText()
        let pasteCalls = await h.paste.callCount()
        XCTAssertEqual(unicode, "hello world")
        XCTAssertEqual(pasteCalls, 0)
    }

    func test_missingStrategyStartsAtTheTopOfTheChain() async {
        // A host without AX (e.g. sandboxed): the policy still picks AX, the chain starts at paste.
        let h = makeHarness(chain: { _, paste, unicode in InjectorChain([(.paste, paste), (.unicodeType, unicode)]) })
        await runUtterance(h)
        let axCalls = await h.ax.callCount()
        let pasted = await h.paste.injectedText()
        XCTAssertEqual(axCalls, 0)
        XCTAssertEqual(pasted, "hello world")
    }

    func test_chainWithoutPasteCopiesWhenThereIsNoElement() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.google.Chrome", hasTarget: false, axGranted: true))
        let h = makeHarness(context: context, chain: { ax, _, unicode in InjectorChain([(.axSelectedText, ax), (.unicodeType, unicode)]) })
        let states = await collectStates(h)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        let unicodeCalls = await h.unicode.callCount()
        XCTAssertEqual(copied, ["hello world"])
        XCTAssertEqual(unicodeCalls, 0, "never unicode-type into an unknown focus")
        let settled = await states.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.copiedNoTarget), .idle])
    }

    func test_emptyChainFallsToTheClipboard() async {
        let h = makeHarness(chain: { _, _, _ in InjectorChain([]) })
        let states = await collectStates(h)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        XCTAssertEqual(copied, ["hello world"], "speech is never dropped (CLAUDE.md)")
        let settled = await states.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.copiedNoTarget), .idle])
    }

    func test_customPolicyPicksTheFirstStrategy() async {
        let h = makeHarness(injectionPolicy: AlwaysPaste())
        await runUtterance(h)
        let axCalls = await h.ax.callCount()
        let pasted = await h.paste.injectedText()
        XCTAssertEqual(axCalls, 0)
        XCTAssertEqual(pasted, "hello world")
    }

    func test_chainOrderAndLookup() {
        let chain = InjectorChain([(.unicodeType, RecordingInjector()), (.paste, RecordingInjector())])
        XCTAssertEqual(chain.strategies, [.unicodeType, .paste])
        XCTAssertNil(chain.injector(for: .axSelectedText))
        XCTAssertEqual(chain.fallback(after: .unicodeType), .paste)
        XCTAssertNil(chain.fallback(after: .paste))
        XCTAssertNil(chain.fallback(after: .axSelectedText), "not in the chain")
        XCTAssertEqual(chain.attempts(startingAt: .axSelectedText).map(\.strategy), [.unicodeType, .paste])
        XCTAssertEqual(chain.attempts(startingAt: .paste).map(\.strategy), [.paste])
    }

    func test_defaultChainKeepsTodaysOrder() {
        let chain = InjectorChain(ax: RecordingInjector(), paste: RecordingInjector(), unicode: RecordingInjector())
        XCTAssertEqual(chain.strategies, [.axSelectedText, .paste, .unicodeType])
    }
}
