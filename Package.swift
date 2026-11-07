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
    ],
    dependencies: [
        .package(path: "../Grammar"),
        .package(path: "../Lexer"),
        .package(path: "../Parser"),
        .package(path: "../Earley-Parser"),
        .package(path: "../Incremental-Parsing"),
        .package(path: "../Language-Tooling"),
    ],

    targets: [
        .target(
            name: "PascalLanguage",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Lexer", package: "Lexer"),
                .product(name: "Parser", package: "Parser"),
                .product(name: "Earley-Parser", package: "Earley-Parser"),
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
                .product(name: "LanguageTooling", package: "Language-Tooling"),
            ],
            resources: [.process("Resources")],
        ),
        .target(name: "PascalConformance"),
        .target(
            name: "PascalFrontendConformance",
            dependencies: [
                "PascalLanguage", "PascalConformance",
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            ]
        ),
        .testTarget(
            name: "PascalLanguageTests",
            dependencies: [
                "PascalLanguage", "PascalConformance", "PascalFrontendConformance",
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
                .product(name: "LanguageTooling", package: "Language-Tooling"),
            ]
        ),
    ]
)
