import Foundation

/// The injectors `DictationSession` walks, in fallback order (PLAN §4). It starts at the strategy
/// the `InjectionPolicy` picks and moves down the list on `.failed` only (DS-05). A host drops a
/// strategy by leaving it out, reorders, or supplies its own injector for any strategy.
public struct InjectorChain: Sendable {
    public struct Entry: Sendable {
        public let strategy: InjectionStrategy
        public let injector: any TextInjecting

        public init(_ strategy: InjectionStrategy, _ injector: any TextInjecting) {
            self.strategy = strategy
            self.injector = injector
        }
    }

    public let entries: [Entry]

    /// Each strategy at most once: the history `delivery` column names the strategy, not the injector.
    public init(_ ordered: [(InjectionStrategy, any TextInjecting)]) {
        let entries = ordered.map { Entry($0.0, $0.1) }
        precondition(Set(entries.map(\.strategy)).count == entries.count, "InjectorChain: a strategy appears twice")
        self.entries = entries
    }

    /// Today's chain: AX -> paste -> unicode.
    public init(ax: any TextInjecting, paste: any TextInjecting, unicode: any TextInjecting) {
        self.init([(.axSelectedText, ax), (.paste, paste), (.unicodeType, unicode)])
    }

    public var strategies: [InjectionStrategy] { entries.map(\.strategy) }

    public func injector(for strategy: InjectionStrategy) -> (any TextInjecting)? {
        entries.first { $0.strategy == strategy }?.injector
    }

    /// The next strategy down the chain after `strategy`; nil at the end or if it isn't in the chain.
    public func fallback(after strategy: InjectionStrategy) -> InjectionStrategy? {
        guard let i = entries.firstIndex(where: { $0.strategy == strategy }), i + 1 < entries.count else { return nil }
        return entries[i + 1].strategy
    }

    /// What to try for a policy's pick, in order: from it onward. A pick the host left out of the
    /// chain starts at the top, so a dropped strategy degrades to the host's first choice.
    func attempts(startingAt strategy: InjectionStrategy) -> ArraySlice<Entry> {
        guard let i = entries.firstIndex(where: { $0.strategy == strategy }) else { return entries[...] }
        return entries[i...]
    }
}
