// swift-tools-version: 6.0
import PackageDescription

// The package is split so that everything except the window layer is portable:
//
//   OpenborldCore  — providers, transfers, signing. macOS, Linux, Windows.
//   Openborld      — the SwiftUI app. macOS only, by construction.
//   CSQLite        — the system sqlite3, exposed the same way on every platform.
//
// `Openborld` is declared unconditionally because SwiftPM manifests cannot be
// made conditional on the host OS; building it elsewhere fails at the SwiftUI
// import, which is the honest outcome. On Linux and Windows build the library
// and the test runner:  swift build --product openborld-tests
let package = Package(
    name: "Openborld",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Openborld", targets: ["Openborld"]),
        .executable(name: "openborld-tests", targets: ["OpenborldTestRunner"]),
        .library(name: "OpenborldCore", targets: ["OpenborldCore"]),
    ],
    dependencies: [
        // Apple's own implementation. On Apple platforms it forwards to
        // CryptoKit, so one `import Crypto` covers every target OS and the
        // signing code needs no conditional compilation.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "OpenborldCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                "CSQLite",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "Openborld",
            dependencies: ["OpenborldCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenborldTestRunner",
            dependencies: ["OpenborldCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
