// Voice commands inside `DictationSession`: the command key, the "Sotto, ..." prefix on the dictation
// key, and the confirm state machine for Shortcuts set to Ask first.
//
// Rules this file keeps (spec: command mode):
// - A command never types, presses a key, touches the pasteboard, calls cleanup or writes History.
// - Nothing here logs a transcript or a target name; the log carries closed enums and counts.
// - There is no Esc: a confirm ends by a tap (command key-down), a dictation-key press, or 8 s (10 s
//   with VoiceOver).
import Foundation
import os

enum CommandRoute: Sendable {
    case resolved(ResolvedCommand)
    case failed(CommandFailure)
}

/// One confirm in flight. Only the session actor touches it; `decide` is the single exit.
final class PendingConfirm {
    let id = UUID()
    var state = ConfirmState.pending
    var continuation: CheckedContinuation<ConfirmState, Never>?
    var timer: Task<Void, Never>?
}

extension DictationSession {
    /// Command progress for the indicator. Carries no transcript.
    public func commandPhaseUpdates() -> AsyncStream<CommandPhase> {
        let id = UUID()
        return AsyncStream { continuation in
            commandContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeCommandContinuation(id) }
            }
        }
    }

    /// Test hook: whether "scratch that" would still find an injection to undo.
    @_spi(Testing) public func scratchGuardArmed() -> Bool { lastInjection != nil }

    private func removeCommandContinuation(_ id: UUID) { commandContinuations[id] = nil }

    func emitCommand(_ phase: CommandPhase) {
        for continuation in commandContinuations.values { continuation.yield(phase) }
    }

    // MARK: Cap

    /// A command press stops at 15 s and continues exactly like a release.
    func scheduleCommandCap(generation: Int) {
        commandCapTask?.cancel()
        commandCapTask = Task { [commandSleep, maxCommandRecordingDuration] in
            await commandSleep(maxCommandRecordingDuration)
            guard !Task.isCancelled else { return }
            await self.forceStopIfStillRecording(generation: generation)
        }
    }

    // MARK: Routing

    /// Command key: STT is done. Waits behind any dictation still landing (it lands first), then
    /// rewrites heard-as variants, routes and clears the scratch-that guard, all under the lock.
    func runCommandKeyUtterance(_ transcript: String, inputs: CommandInputs) async {
        // The host's closure runs before the lock, so a slow one never stalls a queued dictation.
        let catalog = await commandCatalogProvider()
        let route = await injectionLock.runExclusive {
            let rewritten = await self.commandRewrite(transcript)
            let route: CommandRoute
            switch CommandRouter.routeCommandKey(rewritten, catalog: catalog) {
            case .resolved(let command): route = .resolved(command)
            case .failed(let failure): route = .failed(failure)
            }
            await self.clearScratchGuard() // every outcome, errors and noMatch included, refuses "scratch that"
            return route
        }
        await perform(route, source: .commandKey, inputs: inputs)
    }

    /// Dictation key, under the injection lock. Exact "scratch that" was handled by the caller; this
    /// is the prefix. Nil means "it is dictation".
    func routeDictationPrefix(_ transcript: String, inputs: CommandInputs) async -> CommandRoute? {
        guard commandExecutor != nil, inputs.commandsEnabled, inputs.prefixEnabled else { return nil }
        let rewritten = await commandRewrite(transcript)
        guard CommandRouter.hasCommandPrefix(rewritten) else { return nil } // no catalogue read for prose
        let catalog = await commandCatalogProvider()
        let route: CommandRoute
        switch CommandRouter.routeDictationKey(rewritten, catalog: catalog, prefixEnabled: true) {
        case .command(let command): route = .resolved(command)
        case .commandError(let failure): route = .failed(failure)
        case .scratchThat, .dictation: return nil
        }
        lastInjection = nil
        emitCommand(.recognisedAsCommand)
        return route
    }

    func clearScratchGuard() { lastInjection = nil }

    func runPrefixCommand(_ route: CommandRoute, inputs: CommandInputs) async {
        await perform(route, source: .prefix, inputs: inputs)
    }

    // MARK: Execute

    enum CommandSource { case commandKey, prefix }

    private func perform(_ route: CommandRoute, source: CommandSource, inputs: CommandInputs) async {
        defer { if !isRecording { emit(.idle) } } // never over a newer press that already started
        switch route {
        case .failed(let failure):
            log.info("command: failed (\(String(describing: source), privacy: .public), \(failure.kind.rawValue, privacy: .public))")
            emitCommand(.failed(failure))
        case .resolved(let command):
            guard let executor = commandExecutor else { return }
            var isShortcut = false
            if case .runShortcut(let shortcut) = command {
                isShortcut = true
                if shortcut.askFirst {
                    // The prefix path has no key press of its own, so it needs a bound command key.
                    if source == .prefix, !inputs.confirmKeyAvailable {
                        emitCommand(.failed(.confirmKeyUnavailable))
                        return
                    }
                    guard await awaitConfirm(shortcut: shortcut.name, timeout: inputs.confirmTimeout) == .confirmed else { return }
                }
                emitCommand(.running(shortcut: shortcut.name))
            } else {
                emitCommand(.acting(command))
            }
            // Bringing an app forward holds the lock so a queued dictation can't type into the wrong
            // app meanwhile. A Shortcut can run for minutes and doesn't move focus, so it doesn't.
            // Either way the guard is cleared after the command (spec: "after any command").
            let outcome: CommandOutcome
            if isShortcut {
                outcome = await executor.execute(command)
                await injectionLock.runExclusive { await self.clearScratchGuard() }
            } else {
                outcome = await injectionLock.runExclusive {
                    let outcome = await executor.execute(command)
                    await self.clearScratchGuard()
                    return outcome
                }
            }
            log.info("command: finished (\(String(describing: outcome), privacy: .public))")
            emitCommand(.finished(outcome))
        }
    }

    // MARK: Confirm

    private func awaitConfirm(shortcut: String, timeout: Duration) async -> ConfirmState {
        decideConfirm(.cancelled) // one confirm at a time
        let confirm = PendingConfirm()
        return await withCheckedContinuation { continuation in
            // Registered and armed in one synchronous step: no tap or timeout can slip between.
            confirm.continuation = continuation
            pendingConfirm = confirm
            confirm.timer = Task { [commandSleep] in
                await commandSleep(timeout)
                guard !Task.isCancelled else { return }
                await self.confirmTimedOut(confirm.id)
            }
            emitCommand(.confirmPending(shortcut: shortcut))
        }
    }

    private func confirmTimedOut(_ id: UUID) {
        guard pendingConfirm?.id == id else { return }
        decideConfirm(.timedOut)
    }

    /// The only way out of `pending`: the first caller wins and a later one gets false, so a tap and
    /// the timeout at the same instant yield exactly one outcome.
    @discardableResult
    func decideConfirm(_ outcome: ConfirmState) -> Bool {
        guard let confirm = pendingConfirm, confirm.state == .pending else { return false }
        confirm.state = outcome
        confirm.timer?.cancel()
        pendingConfirm = nil
        if outcome != .confirmed { emitCommand(.cancelled) }
        confirm.continuation?.resume(returning: outcome)
        confirm.continuation = nil
        return true
    }
}
