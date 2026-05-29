// swift-tools-version: 6.0
import PackageDescription

// OnsetKit — layered library package for the Onset macOS app.
//
// Layer edges are enforced two ways:
//   1. The compiler: a target can only import targets listed in its `dependencies`.
//   2. CI: `ci.yml` job `hard-gates` re-asserts the graph from `swift package dump-package`,
//      because this manifest is agent-editable and the compiler check is therefore not
//      tamper-resistant against an agent that adds an edge here.
//
// Dependency direction (inward): Presentation -> Application -> Domain <- Infrastructure.
// Domain has no dependencies. Application and Infrastructure must NOT depend on each other,
// and nothing may depend on Presentation.
let package = Package(
    name: "OnsetKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Application", targets: ["Application"]),
        .library(name: "Infrastructure", targets: ["Infrastructure"]),
        .library(name: "Presentation", targets: ["Presentation"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Application", dependencies: ["Domain"]),
        .target(name: "Infrastructure", dependencies: ["Domain"]),
        .target(
            name: "Presentation",
            dependencies: ["Application", "Domain"],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "ApplicationTests", dependencies: ["Application", "Domain"]),
    ]
)
