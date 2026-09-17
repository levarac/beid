// swift-tools-version: 5.9

import PackageDescription

// SwiftPM only, deliberately. This tool is built with `swift build` on a lab
// host and bundled into a .app by scripts/bundle.sh; it is not part of the
// XcodeGen project and must never need one. `ios/project.yml` stays the
// authority for the app.
//
// The Barnard pin is `exact` and must equal `ios/project.yml`'s `exactVersion`.
// A lab CLI that measured a different SDK than the app ships would produce
// numbers nobody could use, so `scripts/check_lab_cli_barnard_pin.py` fails
// the two apart.
let package = Package(
    name: "beid-lab-cli",
    // Matches the floor the Barnard package declares. The sources need nothing
    // newer than CBManager.authorization (macOS 10.15+).
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "beid-lab-cli", targets: ["beid-lab-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/levarac/barnard.git", exact: "0.9.2")
    ],
    targets: [
        // Everything decidable without a radio: argument parsing, the JSON
        // line schema, the level filter, redaction, and the observer's
        // seen/lost reducer. It imports Foundation and nothing else, so
        // `swift test` runs on a host with no Bluetooth — which is every CI
        // runner GitHub offers.
        .target(name: "BeidLabCliCore", path: "Sources/BeidLabCliCore"),
        .executableTarget(
            name: "beid-lab-cli",
            dependencies: [
                "BeidLabCliCore",
                .product(name: "Barnard", package: "barnard"),
                // BarnardCore carries the B005 v2 container reader the venue
                // subcommand uses to describe what it is about to serve.
                .product(name: "BarnardCore", package: "barnard")
            ],
            path: "Sources/beid-lab-cli"
        ),
        .testTarget(
            name: "BeidLabCliCoreTests",
            dependencies: ["BeidLabCliCore"],
            path: "Tests/BeidLabCliCoreTests"
        )
    ]
)
