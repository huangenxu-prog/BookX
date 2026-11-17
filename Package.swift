// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BookXCore",
    platforms: [.macOS(.v12)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")],
    targets: [
        .target(name: "BookXCore", dependencies: ["ZIPFoundation"], path: "BookX",
                exclude: ["BookXApp.swift", "ReaderView.swift", "CurlPageView.swift", "BookSpeech.swift", "EPUBReader.swift", "Assets.xcassets"], sources: ["BookDocument.swift", "ScreenPagination.swift", "EPUBReadingEngine.swift", "BookItem.swift"]),
        .testTarget(name: "BookXCoreTests", dependencies: ["BookXCore"], path: "Tests",
                    resources: [.copy("Fixtures")])
    ]
)
