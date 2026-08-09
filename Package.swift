// swift-tools-version: 6.0
import PackageDescription

// Swift Testing ships with the Command Line Tools toolchain at a
// non-default framework search path. The FluxCoreTests target declares that
// path so `swift test` builds on CLT-only machines (no full Xcode, no XCTest).
// On toolchains that already find Swift Testing (full Xcode) these flags are
// additive and harmless. Use `scripts/test.sh`: a bare `swift test` can build
// but silently skip execution because SwiftPM does not pass target-specific
// search paths to its generated runner on a CLT-only installation.
//
// CLT quirk: SwiftPM does not forward `-F` from unsafeFlags to the generated
// test runner, so on CLT-only machines test discovery needs the CLI form:
//   scripts/test.sh
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltSwiftLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Flux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FluxCore", targets: ["FluxCore"]),
        .executable(name: "FluxApp", targets: ["FluxApp"]),
    ],
    targets: [
        .target(name: "FluxCore"),
        .executableTarget(
            name: "FluxApp",
            dependencies: ["FluxCore"]
        ),
        .testTarget(
            name: "FluxCoreTests",
            dependencies: ["FluxCore"],
            swiftSettings: [
                .unsafeFlags(["-F", cltFrameworks])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltSwiftLibraries,
                ])
            ]
        ),
    ]
)
