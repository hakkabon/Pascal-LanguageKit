// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Pascal-LanguageKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PascalLanguage", targets: ["PascalLanguage"]),
        .library(name: "PascalConformance", targets: ["PascalConformance"]),
        .library(name: "PascalFrontendConformance", targets: ["PascalFrontendConformance"]),
//        .library(name: "LanguageExperimentProtocol", targets: ["LanguageExperimentProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hakkabon/Grammar.git", from: "0.3.4"),
    ],
    
    targets: [
        .target(
            name: "PascalLanguage",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
            ],
            resources: [.process("Resources")],
        ),
        .target(name: "PascalConformance"),
        .target(
            name: "PascalFrontendConformance",
            dependencies: ["PascalLanguage", "PascalConformance"]
        ),
        .testTarget(
            name: "PascalLanguageTests",
            dependencies: ["PascalLanguage"]
        ),
    ]
)
