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
            var lastProbe = "no JavaScript result"
            for _ in 0..<80 {
                let result = await navigator.evaluateJavaScript("""
                    (() => {
                        const p = document.getElementById('styled');
                        const img = document.querySelector('img');
                        return JSON.stringify({
                            url: document.URL,
                            readyState: document.readyState,
                            text: document.body?.innerText?.slice(0, 100),
                            paragraph: !!p,
                            color: p ? getComputedStyle(p).color : null,
                            image: !!img,
                            imageComplete: img?.complete,
                            imageWidth: img?.naturalWidth,
                            imageURL: img?.currentSrc,
                            stylesheets: document.styleSheets.length
                        });
                    })()
                    """)
                switch result {
                case .success(let value):
                    lastProbe = "result=\(String(describing: value))"
                    if let json = value as? String,
                       let data = json.data(using: .utf8),
                       let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       (probe["paragraph"] as? Bool) == true,
                       (probe["imageWidth"] as? Int ?? 0) > 0,
                       (probe["color"] as? String) == "rgb(121, 33, 44)" { rendered = true }
                case .failure(let error):
                    lastProbe = "error=\(error.localizedDescription)"
                }
                if rendered { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if !rendered {
                let attachment = XCTAttachment(string: "Publication: \(name)\nWebKit: \(lastProbe)")
                attachment.name = "Readium-WebKit-\(name)-diagnostics"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTFail("Readium \(name) failed; WebKit diagnostic: \(lastProbe)")
            }
            let moved = await navigator.go(to: publication.readingOrder[1], options: .init())
            XCTAssertTrue(moved)
            // Readium updates currentLocation after the navigation state returns to idle.
            // go(to:) can succeed before the deferred location notification is processed.
            var locationHref = navigator.currentLocation?.href.string ?? ""
            for _ in 0..<40 where !locationHref.contains("two.xhtml") {
                try await Task.sleep(nanoseconds: 250_000_000)
                locationHref = navigator.currentLocation?.href.string ?? ""
            }
            XCTAssertTrue(locationHref.contains("two.xhtml"),
                          "Readium navigation succeeded but currentLocation stayed at: \(locationHref)")
        }

        // The production reader must still instantiate UIKit's pageCurl.
        let page = ReadingPage(offset: 0, text: "保留仿真翻页")
        let curl = CurlPageView(pages: [page], bookURL: nil, currentPage: .constant(0),
            fontSize: 19, lineSpacing: 8, ink: .black, background: .white,
            header: AnyView(EmptyView()), topInset: 0, bottomInset: 0,
            contentID: UUID(), positionLabels: ["1 / 1"])
        let host = UIHostingController(rootView: curl)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let curlWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        curlWindow.rootViewController = host
        curlWindow.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        defer { curlWindow.isHidden = true; curlWindow.rootViewController = nil }
        func findCurl(_ root: UIViewController) -> UIPageViewController? {
            if let page = root as? UIPageViewController { return page }
            for child in root.children {
                if let found = findCurl(child) { return found }
            }
            return nil
        }
        let controller = try XCTUnwrap(findCurl(host), "SwiftUI may nest the page controller under hosting containers")
        XCTAssertEqual(controller.transitionStyle, UIPageViewController.TransitionStyle.pageCurl)
    }
}
