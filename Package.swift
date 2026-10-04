// swift-tools-version: 6.0
//
//  Package.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import PackageDescription

let package = Package(
  name: "swift-yamlkit",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9)
  ],
  products: [
    .library(name: "YamlKit", targets: ["YamlKit"])
  ],
  dependencies: [
    // Only used by the tests; packages depending on YamlKit do not fetch it.
    .package(url: "https://github.com/objecthub/swift-dynamicjson.git", from: "1.0.2")
  ],
  targets: [
    .target(
      name: "YamlKit",
      path: "Sources/YamlKit"
    ),
    .testTarget(
      name: "YamlKitTests",
      dependencies: [
        "YamlKit",
        .product(name: "DynamicJSON", package: "swift-dynamicjson")
      ],
      path: "Tests/YamlKitTests",
      resources: [
        .copy("Resources/yaml-test-suite")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
