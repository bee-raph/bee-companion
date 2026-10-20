// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Companion", platforms: [.macOS(.v14)],
  products: [.executable(name: "Companion", targets: ["Companion"])],
  dependencies: [
    .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
  ],
  targets: [
    .executableTarget(
      name: "Companion",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
      ], resources: [.process("Resources")]),
    .testTarget(name: "CompanionTests", dependencies: ["Companion"]),
  ])
