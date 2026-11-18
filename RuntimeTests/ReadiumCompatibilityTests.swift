import XCTest
import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
@testable import BookX

@MainActor
final class ReadiumCompatibilityTests: XCTestCase {
    func testEPUB2And3ResourcesAndNativeCurlRemainAvailable() async throws {
        for name in ["readium2", "readium3"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "epub"))
            let publication = try await ReadiumPublicationStore.shared.open(source)
            XCTAssertEqual(publication.readingOrder.count, 2)
            XCTAssertEqual(publication.manifest.tableOfContents.count, 2)
            let first = try XCTUnwrap(publication.get(publication.readingOrder[0]))
            let html = try await first.readAsString().get()
            XCTAssertTrue(html.contains("第一章图文"))
            let imageLink = try XCTUnwrap(publication.resources.first { $0.url().string.hasSuffix("image.png") })
            let image = try XCTUnwrap(publication.get(imageLink))
            let bytes = try await image.read().get()
            XCTAssertNotNil(UIImage(data: bytes))

            let navigator = try EPUBNavigatorViewController(
                publication: publication, initialLocation: nil,
                config: .init(preferences: EPUBPreferences(publisherStyles: true, scroll: false))
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = navigator
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }

            var rendered = false
            for _ in 0..<80 {
                if case .success(let value) = await navigator.evaluateJavaScript("""
                    (() => {
                        const p = document.getElementById('styled');
                        const img = document.querySelector('img');
                        return !!p && !!img && img.complete && img.naturalWidth > 0
                            && getComputedStyle(p).color === 'rgb(121, 33, 44)';
                    })()
                    """), (value as? Bool) == true {
                    rendered = true
                    break
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            XCTAssertTrue(rendered, "Readium must render both CSS and the embedded image")
            let moved = await navigator.go(to: publication.readingOrder[1], options: .init())
            XCTAssertTrue(moved)
            let locator = try XCTUnwrap(navigator.currentLocation)
            XCTAssertTrue(locator.href.string.contains("two.xhtml"))
        }

        // The production reader must still instantiate UIKit's pageCurl.
        let page = ReadingPage(offset: 0, text: "保留仿真翻页")
        let curl = CurlPageView(pages: [page], currentPage: .constant(0),
            fontSize: 19, lineSpacing: 8, ink: .black, background: .white,
            header: AnyView(EmptyView()), topInset: 0, bottomInset: 0,
            contentID: UUID(), positionLabels: ["1 / 1"])
        let host = UIHostingController(rootView: curl)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        let controller = try XCTUnwrap(host.children.first as? UIPageViewController)
        XCTAssertEqual(controller.transitionStyle, .pageCurl)
    }
}
