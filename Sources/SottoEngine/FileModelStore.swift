// Model weights (SPEC §6): one GGUF in the directory the host names (ADR §5). `ensureDownloaded`
// is the only fetch. Downloads land in `<file>.partial` and only become the real file after the
// sha256 matches, so a quit or crash mid-download can never hand llama a truncated model (MS-07).
// At launch only the size is checked (MS-08): re-hashing 2.5GB costs seconds of disk every start.
import CryptoKit
import Foundation
import SottoCore
import os

public struct ModelSpec: Sendable {
    public let id: ModelID
    public let fileName: String
    public let url: URL
    public let sha256: String
    public let size: Int64
    public let displayName: String

    public init(id: ModelID, fileName: String, url: URL, sha256: String, size: Int64, displayName: String) {
        (self.id, self.fileName, self.url, self.sha256, self.size, self.displayName) = (id, fileName, url, sha256, size, displayName)
    }

    // unsloth at a pinned revision: byte-identical to the file Phase 0 measured.
    public static let qwen3_4b = ModelSpec(
        id: ModelID("qwen3-4b-instruct-2507-q4_k_m"),
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        size: 2_497_281_120,
        displayName: "Qwen3-4B"
    )
}

public actor FileModelStore: ModelStore {
    public enum Failure: Error, CustomStringConvertible {
        case unknownModel, http(Int), incomplete, checksum, rangeNotSatisfiable, fetchDisabled
        public var description: String {
            switch self {
            case .rangeNotSatisfiable: "server rejected the resume range"
            case .fetchDisabled: "dry run: no model download"
            case .unknownModel: "unknown model"
            case .http(let code): "server returned \(code)"
            case .incomplete: "download incomplete"
            case .checksum: "checksum mismatch"
            }
        }
    }

    private let log: Logger
    private let specs: [ModelID: ModelSpec]
    private let directory: URL
    private let devSources: [URL]
    private let allowFetch: Bool
    private var inFlight: [ModelID: Task<Void, Error>] = [:]
    private var observers: [ModelID: [@Sendable (Double) -> Void]] = [:]
    private var progress: [ModelID: Double] = [:]
    private var failures: [ModelID: String] = [:]

    /// `devSources`: directories to clone a matching file from instead of downloading (dev builds).
    /// `allowFetch` false (dry runs) uses an existing model only: the host's daily copy may share this directory,
    /// and two processes appending to one `.partial` corrupt it.
    public init(specs: [ModelSpec] = [.qwen3_4b], directory: URL, devSources: [URL] = [], allowFetch: Bool = true, log: LogSubsystem) {
        self.specs = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        self.directory = directory
        self.devSources = devSources
        self.allowFetch = allowFetch
        self.log = log.logger("models")
    }

    public func availability(for model: ModelID) -> ModelAvailability {
        if let p = progress[model] { return .downloading(progress: p) }
        if let reason = failures[model] { return .failed(reason: reason) }
        guard let spec = specs[model] else { return .failed(reason: Failure.unknownModel.description) }
        return isComplete(spec) ? .ready : .notDownloaded
    }

    public func url(for model: ModelID) -> URL? {
        guard let spec = specs[model], isComplete(spec) else { return nil }
        return finalURL(spec)
    }

    public func ensureDownloaded(_ model: ModelID, progress onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let spec = specs[model] else { throw Failure.unknownModel }
        if isComplete(spec) { return }
        observers[model, default: []].append(onProgress)
        if let running = inFlight[model] { return try await running.value }

        failures[model] = nil
        progress[model] = 0
        let task = Task { try await self.fetch(spec) }
        inFlight[model] = task
        defer {
            inFlight[model] = nil
            observers[model] = nil
            progress[model] = nil
        }
        do {
            try await task.value
            log.info("model ready: \(spec.fileName, privacy: .public)")
        } catch {
            failures[model] = String(describing: error)
            log.error("model fetch failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func report(_ model: ModelID, _ fraction: Double) {
        progress[model] = fraction
        for observer in observers[model] ?? [] { observer(fraction) }
    }

    private func fetch(_ spec: ModelSpec) async throws {
        guard allowFetch else { throw Failure.fetchDisabled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = finalURL(spec)
        try? FileManager.default.removeItem(at: final)  // wrong size: never trust it

        if let dev = devSources.map({ $0.appendingPathComponent(spec.fileName) }).first(where: { Self.size(of: $0) == spec.size }) {
            log.info("cloning dev model from \(dev.deletingLastPathComponent().path, privacy: .public)")
            guard try await Self.sha256(of: dev) == spec.sha256 else { throw Failure.checksum }
            // A copy, not a link: the checkout may be deleted. APFS clones it, so no extra disk.
            try FileManager.default.copyItem(at: dev.resolvingSymlinksInPath(), to: final)
            return
        }

        let partial = directory.appendingPathComponent(spec.fileName + ".partial")
        // A quit during the hash leaves a full partial; resuming it would 416 forever.
        if let have = Self.size(of: partial), have > spec.size { try FileManager.default.removeItem(at: partial) }
        if Self.size(of: partial) != spec.size {
            do {
                try await download(spec, to: partial)
            } catch Failure.rangeNotSatisfiable {
                try? FileManager.default.removeItem(at: partial)
                try await download(spec, to: partial)
            }
        }
        guard Self.size(of: partial) == spec.size else { throw Failure.incomplete }
        guard try await Self.sha256(of: partial) == spec.sha256 else {
            try? FileManager.default.removeItem(at: partial)  // MS-02: a bad body must not be resumed
            throw Failure.checksum
        }
        try FileManager.default.moveItem(at: partial, to: final)
    }

    private func download(_ spec: ModelSpec, to partial: URL) async throws {
        try await RangedDownload(file: partial, expected: spec.size) { fraction in
            Task { await self.report(spec.id, fraction) }
        }.run(spec.url)
    }

    private func finalURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName) }

    private func isComplete(_ spec: ModelSpec) -> Bool { Self.size(of: finalURL(spec)) == spec.size }

    static func size(of url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Streams into `file`, resuming with `Range` when a partial exists. A server that ignores the
/// range (200 instead of 206) restarts from zero rather than appending a full body (MS-04).
private final class RangedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked: URLSession calls the delegate serially on its own queue; `run` only sets up.
    private let file: URL
    private let expected: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReported = -1.0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(file: URL, expected: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.file = file
        self.expected = expected
        self.onProgress = onProgress
    }

    func run(_ url: URL) async throws {
        written = FileModelStore.size(of: file) ?? 0
        var request = URLRequest(url: url)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                handle = try FileHandle(forWritingTo: file)
                try handle?.seekToEnd()
            case 200:
                FileManager.default.createFile(atPath: file.path, contents: nil)  // truncates
                handle = try FileHandle(forWritingTo: file)
                written = 0
            case 416:
                failure = FileModelStore.Failure.rangeNotSatisfiable
                return .cancel
            default:
                failure = FileModelStore.Failure.http(status)
                return .cancel
            }
        } catch {
            failure = error
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            let fraction = min(1, Double(written) / Double(expected))
            if fraction - lastReported >= 0.01 || fraction == 1 {
                lastReported = fraction
                onProgress(fraction)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error = failure ?? error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}
