import XCTest
@testable import BookXCore

final class EPUBOnDemandTests: XCTestCase {
    private let layout = ReadingLayout(size: CGSize(width: 393, height: 650), font: 19, spacing: 8, paged: true)
    private func source(_ name: String) throws -> URL {
        let original = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/" + name))
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: original, to: target)
        addTeardownBlock { EPUBResourceStore.remove(target); BookDocumentStore.remove(target); try? FileManager.default.removeItem(at: target) }
        return target
    }
    func testHistoricalLibraryJSONAndNewBookmarkRoundTrip() async throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000001","title":"旧书","author":"作者","filename":"old.epub","progress":0.5,"readingOffset":1234,"hiddenFromShelf":true}]"#
        var books = try JSONDecoder().decode([BookItem].self, from: Data(json.utf8))
        XCTAssertNil(books[0].epubLocation)
        XCTAssertEqual(books[0].readingOffset, 1234)
        XCTAssertEqual(books[0].hiddenFromShelf, true)
        books[0].epubLocation = EPUBLocation(resource: 3, offset: 456)
        let restored = try JSONDecoder().decode([BookItem].self, from: JSONEncoder().encode(books))
        XCTAssertEqual(restored[0].epubLocation, books[0].epubLocation)
        XCTAssertEqual(restored[0].id, books[0].id)
    }
    func testIndexAndFirstChapterDoNotParseLaterBrokenXHTML() async throws {
        let url = try source("lazy.epub")
        let index = try await EPUBResourceStore.index(url)
        XCTAssertEqual(index.resources.count, 4)
        XCTAssertEqual(index.resources.map(\.title), ["目录1", "目录2", "目录3", "目录4"])
        let chapter = try await EPUBReadingEngine.chapter(url, index: index, at: 0, layout: layout)
        XCTAssertGreaterThan(chapter.pages.count, 1)
        XCTAssertTrue(chapter.pages.allSatisfy { $0.resourceIndex == 0 })
        do { _ = try await EPUBReadingEngine.chapter(url, index: index, at: 3, layout: layout); XCTFail("Expected an error") } catch { }
    }
    func testEPUB3NavigationAndEmptyChapterTraversal() async throws {
        let nav = try await EPUBResourceStore.index(source("nav3.epub"))
        XCTAssertEqual(nav.resources.map(\.title), ["目录1", "目录2"])
        let url = try source("lazy.epub"), index = try await EPUBResourceStore.index(url)
        let actual1 = try await EPUBReadingEngine.readableChapter(url, index: index, startingAt: 1, direction: 1, layout: layout)?.resource
        XCTAssertEqual(actual1, 2)
        let actual2 = try await EPUBReadingEngine.readableChapter(url, index: index, startingAt: 1, direction: -1, layout: layout)?.resource
        XCTAssertEqual(actual2, 0)
        let actual3 = try await EPUBReadingEngine.readableChapter(url, index: index, startingAt: -1, direction: -1, layout: layout)
        XCTAssertNil(actual3)
    }
    func testWindowPrependEvictionAndBidirectionalChapterBoundaries() async throws {
        let url = try source("nav3.epub"), index = try await EPUBResourceStore.index(url)
        let first = try await EPUBReadingEngine.chapter(url, index: index, at: 0, layout: layout)
        let second = try await EPUBReadingEngine.chapter(url, index: index, at: 1, layout: layout)
        let anchor = second.pages[1].location
        let window = EPUBWindow.adding(first, to: [1: second], anchor: anchor)
        XCTAssertEqual(window.pages[window.selected].location, anchor)
        XCTAssertEqual(window.pages[first.pages.count - 1].resourceIndex, 0)
        XCTAssertEqual(window.pages[first.pages.count].resourceIndex, 1)
        var chapters = window.chapters
        for resource in 2..<20 {
            let page = ReadingPage(offset: 0, text: "chapter", resourceIndex: resource)
            let next = EPUBWindow.adding(EPUBChapterPages(resource: resource, length: 7, pages: [page]), to: chapters, anchor: page.location)
            chapters = next.chapters
            XCTAssertLessThanOrEqual(chapters.count, 5)
            XCTAssertEqual(next.pages[next.selected].location, page.location)
        }
    }
    func testBookmarkReflowAndLegacyMigrationUseUTF16() async throws {
        let url = try source("nav3.epub"), index = try await EPUBResourceStore.index(url)
        let first = try await EPUBReadingEngine.chapter(url, index: index, at: 0, layout: layout)
        let second = try await EPUBReadingEngine.chapter(url, index: index, at: 1, layout: layout)
        let anchor = second.pages[1].location
        XCTAssertEqual(try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(anchor)), anchor)
        let actual4 = try await EPUBReadingEngine.legacyLocation(url, index: index, offset: first.length + 2 + anchor.offset)
        XCTAssertEqual(actual4, anchor)
        let large = try await EPUBReadingEngine.chapter(url, index: index, at: 1,
            layout: ReadingLayout(size: layout.size, font: 30, spacing: 16, paged: true))
        let resumed = large.pages[BookPagination.pageIndex(for: anchor.offset, in: large.pages)]
        XCTAssertLessThanOrEqual(resumed.offset, anchor.offset)
        XCTAssertGreaterThan(resumed.offset + resumed.text.utf16.count, anchor.offset)
        let flow = BookPagination.pages(second.pages.map(\.text).joined(), fontSize: 19)
        var offset = 0
        for page in flow { XCTAssertEqual(page.offset, offset); offset += page.text.utf16.count }
    }
    func testCacheReopenReplacementAndConcurrentReaders() async throws {
        let url = try source("nav3.epub"), index = try await EPUBResourceStore.index(url)
        let expected = try await EPUBResourceStore.chapter(url, index: index, at: 0)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await EPUBResourceStore.chapter(url, index: index, at: 0) } }
            for try await text in group { XCTAssertEqual(text, expected) }
        }
        let replacement = try source("lazy.epub")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacement, to: url)
        let actual5 = try await EPUBResourceStore.index(url).resources.count
        XCTAssertEqual(actual5, 4)
        let fresh = try await EPUBResourceStore.index(url)
        let actual6 = try await EPUBResourceStore.chapter(url, index: fresh, at: 1)
        XCTAssertEqual(actual6, "")
    }
    func testCancellationPropagatesToBackgroundWorker() async throws {
        let task = Task {
            try await readerWorker {
                while true { try Task.checkCancellation() }
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled worker returned successfully") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testLargeSpineOpensOnlyRequestedResource() async throws {
        let url = try source("large.epub")
        let start = Date()
        let index = try await EPUBResourceStore.index(url)
        let first = try await EPUBReadingEngine.chapter(url, index: index, at: 0, layout: layout)
        XCTAssertEqual(index.resources.count, 1836)
        XCTAssertTrue(first.pages.map(\.text).joined().hasPrefix("章节0"))
        print("BOOKX_BENCH synthetic 1836-resource cold index + first chapter: \(Date().timeIntervalSince(start)) seconds (macOS, not iPhone)")
        let last = try await EPUBReadingEngine.chapter(url, index: index, at: 1835, layout: layout)
        XCTAssertTrue(last.pages.map(\.text).joined().hasPrefix("章节1835"))
    }
}
