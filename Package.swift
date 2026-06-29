// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

//
//  Package.swift
//  framework
//
//  Created by Matt Hamann on 7/8/22.
//

import PackageDescription

let package = Package(
    name: "Rownd",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
        .macCatalyst(.v14)
    ],
    products: [
        .library(
            name: "Rownd",
            targets: ["Rownd"]
        )
    ],

    dependencies: [
        .package(
            name: "ReSwift",
            url: "https://github.com/ReSwift/ReSwift",
            .upToNextMajor(from: "6.1.0")
        ),
        .package(
            name: "ReSwiftThunk",
            url: "https://github.com/ReSwift/ReSwift-Thunk",
            .upToNextMajor(from: "2.0.0")
        ),
        .package(
            name: "JWTDecode",
            url: "https://github.com/auth0/JWTDecode.swift",
            .upToNextMajor(from: "2.6.3")
        ),
        .package(
            name: "SwiftKeychainWrapper",
            url: "https://github.com/jrendel/SwiftKeychainWrapper",
            .upToNextMajor(from: "4.0.1")
        ),
        .package(
            name: "Get",
            url: "https://github.com/rownd/Get",
            .upToNextMajor(from: "2.2.0")
        ),
        .package(
            name: "GoogleSignIn",
            url: "https://github.com/google/GoogleSignIn-iOS.git",
            .upToNextMajor(from: "7.0.0")
        ),
        .package(
            name: "Lottie",
            url: "https://github.com/airbnb/lottie-ios",
            .upToNextMajor(from: "4.5.0")
        ),
        .package(
            name: "Factory",
            url: "https://github.com/hmlongco/Factory",
            .upToNextMajor(from: "1.2.8")
        ),
        .package(
            name: "Mocker",
            url: "https://github.com/WeTransfer/Mocker",
            .upToNextMajor(from: "3.0.1")
        ),
        .package(
            name: "Mockingbird",
            url: "https://github.com/birdrides/mockingbird.git",
            .upToNextMinor(from: "0.20.0")
        ),
        .package(
            name: "SuperTokensIOS",
            url: "https://github.com/supertokens/supertokens-ios",
            .upToNextMajor(from: "0.5.0")
        ),
    ],

    targets: [
        .target(
            name: "LBBottomSheet",
            dependencies: [],
            path: "Packages/LBBottomSheet/Sources/LBBottomSheet",
            resources: [.process("Resources")],
            swiftSettings: [
                .define("SPM")
            ]
        ),
        .target(
            name: "AnyCodable",
            path: "Packages/AnyCodable",
            exclude: ["Tests"]
        ),
        .target(
            name: "Gzip",
            dependencies: ["system-zlib"],
            path: "Packages/GzipSwift/Sources/Gzip"
        ),
        .target(
            name: "system-zlib",
            path: "Packages/GzipSwift/Sources/system-zlib"
        ),
        .target(
            name: "Rownd",
            dependencies: [
                "AnyCodable",
                "ReSwift",
                "ReSwiftThunk",
                "JWTDecode",
                "LBBottomSheet",
                "Gzip",
                "SwiftKeychainWrapper",
                "Get",
                "GoogleSignIn",
                "Lottie",
                "Factory",
                "SuperTokensIOS",
            ],
            path: "Sources/Rownd"
        ),
        .testTarget(
            name: "AnyCodableTests",
            dependencies: ["AnyCodable"],
            path: "Packages/AnyCodable/Tests/AnyCodableTests"
        ),
        .testTarget(
            name: "GzipTests",
            dependencies: ["Gzip"],
            path: "Packages/GzipSwift/Tests/GzipTests",
            resources: [.copy("test.txt.gz")]
        ),
        .testTarget(
            name: "RowndTests",
            dependencies: [
                "Mocker",
                "Mockingbird",
                "AnyCodable",
                "ReSwift",
                "ReSwiftThunk",
                "JWTDecode",
                "LBBottomSheet",
                "Gzip",
                "SwiftKeychainWrapper",
                "Get",
                "GoogleSignIn",
                "Lottie",
                "Factory",
                "Rownd"
            ]
        ),
        .testTarget(
            name: "RowndIntegrationTests",
            dependencies: [
                "Rownd"
            ],
            path: "Tests/RowndIntegrationTests"
        )
    ],

    swiftLanguageVersions: [.v5]
)
