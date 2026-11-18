// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BookXCore",
    platforms: [.macOS(.v12)],
    dependencies: [.package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.1")],
    targets: [
        .target(name: "BookXCore", dependencies: [.product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")], path: "BookX",
                exclude: ["BookXApp.swift", "ReaderView.swift", "CurlPageView.swift", "EPUBReader.swift", "ReadiumPublicationStore.swift", "Assets.xcassets"], sources: ["BookDocument.swift", "ScreenPagination.swift", "EPUBReadingEngine.swift", "EPUBContentParser.swift", "BookItem.swift", "EPUBArchive.swift"]),
        .testTarget(name: "BookXCoreTests", dependencies: ["BookXCore"], path: "Tests",
                    resources: [.copy("Fixtures")])
    ]
)
