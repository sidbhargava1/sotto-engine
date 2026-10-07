// `sotto` (engine-docs/CLI.md): the engine's reference surface and smoke test.
import Darwin
import Dispatch
import Foundation

@main
enum SottoCLI {
    static func main() async {
        trapInterrupt()
        let invocation: Invocation
        do {
            switch try Arguments.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                Console.stdout(Arguments.usage + "\n")
                exit(ExitCode.ok.rawValue)
            case .version:
                Console.stdout("sotto \(Arguments.version)\n")
                exit(ExitCode.ok.rawValue)
            case .run(let parsed):
                invocation = parsed
            }
        } catch {
            Console.stderr("sotto: \(error)\n\(Arguments.synopsis)\nRun 'sotto --help' for the options.\n")
            exit(ExitCode.usage.rawValue)
        }
        let runner = Runner(invocation)
        let code = await runner.run()
        await runner.shutdown()
        exit(code.rawValue)
    }

    // nonisolated(unsafe): written once at launch, before anything else runs.
    nonisolated(unsafe) private static var interrupt: DispatchSourceSignal?

    /// Ctrl-C: exit 130 with nothing printed (CLI.md). `_exit` skips static destructors, so a live
    /// llama context can't abort in Metal teardown on the way out; a partial download resumes.
    private static func trapInterrupt() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInteractive))
        source.setEventHandler { _exit(ExitCode.cancelled.rawValue) }
        source.resume()
        interrupt = source
    }
}
