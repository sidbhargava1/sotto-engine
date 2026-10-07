// swift-tools-version: 6.0
// The dictation engine (open-core ADR §1): this directory is what gets published as `sotto-engine`.
// SottoCore is pure logic + protocol seams, with no AppKit, AVFoundation or CoreML import, so the
// whole dictation flow (PLAN §4) runs under test with fakes and zero permissions. SottoEngine holds
// the macOS adapters behind those protocols (audio, Parakeet/SpeechAnalyzer, llama.cpp, injection).
import Foundation
import PackageDescription

// The llama binary target (open-core ADR §6, H1). A checkout with Vendor/llama.xcframework built
// (scripts/build-llama.sh; the private repo's Vendor symlink) links it by path; a consumer resolving
// the package by URL gets the release asset. SOTTO_LLAMA_LOCAL=1 forces the path target; use it
// after building Vendor in a checkout that already resolved the asset (SwiftPM caches this manifest).
// scripts/package-llama.sh rewrites these two lines; the zip it makes is uploaded to that release.
let llamaRelease = "0.1.0"
let llamaChecksum = "a8562ae7a8b1f9469546500c76e5d2b602ba9484abb86e15fcea369bf581a157"  // llama.cpp 7fe450e19305b828c199d602c23a8337aaa1f03b

let llamaIsLocal = Context.environment["SOTTO_LLAMA_LOCAL"] == "1"
    || FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/llama.xcframework")
let llama: Target = llamaIsLocal
    ? .binaryTarget(name: "llama", path: "Vendor/llama.xcframework")
    : .binaryTarget(
        name: "llama",
        url: "https://github.com/sidbhargava1/sotto-engine/releases/download/\(llamaRelease)/llama.xcframework.zip",
        checksum: llamaChecksum
    )

let package = Package(
    name: "SottoEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SottoCore", targets: ["SottoCore"]),
        .library(name: "SottoEngine", targets: ["SottoEngine"]),
        // Session fakes + harness, shared with the host app's tests (ADR step 3). Tests only.
        .library(name: "SottoCoreTestSupport", targets: ["SottoCoreTestSupport"]),
        // The reference CLI and smoke test (engine-docs/CLI.md): public API only, no @testable.
        .executable(name: "sotto", targets: ["SottoCLI"]),
    ],
    dependencies: [
        // Pinned to the version Phase 0 verified; the API moves fast.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .target(name: "SottoCore"),
        .target(
            name: "SottoEngine",
            dependencies: ["SottoCore", .product(name: "FluidAudio", package: "FluidAudio"), "llama"]
        ),
        // Not "sotto": APFS is case-insensitive, so a `sotto` module's build directory would be the
        // host app's `Sotto.build` in any package that has a `Sotto` target.
        .executableTarget(name: "SottoCLI", dependencies: ["SottoCore", "SottoEngine"]),
        // Upstream llama.cpp ships no Package.swift; see `llama` above.
        llama,
        .target(name: "SottoCoreTestSupport", dependencies: ["SottoCore"], path: "Tests/SottoCoreTestSupport"),
        .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore", "SottoCoreTestSupport"], resources: [.copy("Golden")]),
        // Adapter tests that need AVFoundation but no permissions, devices or model weights.
        .testTarget(name: "SottoEngineTests", dependencies: ["SottoEngine", "SottoCore"]),
        // CLI parsing and exit codes (in-process), plus runs of the built binary that need no weights.
        .testTarget(name: "SottoCLITests", dependencies: ["SottoCLI", "SottoCore", "SottoEngine"]),
    ]
)
