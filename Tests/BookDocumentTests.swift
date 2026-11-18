import XCTest
@testable import BookXCore

final class BookDocumentTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
    }
    func testChineseEncodings() async throws {
        let gb = try await BookDocumentLoader.load(fixture("gb18030.txt"))
        XCTAssertTrue(gb.text.hasPrefix("第一章 春天"))
        XCTAssertTrue(gb.text.contains("不能误判"))
        let utf16 = try await BookDocumentLoader.load(fixture("utf16.txt"))
        XCTAssertTrue(utf16.text.contains("带有字节顺序标记"))
    }
    func testEPUBMetadataSpineOrderAndEscapedPaths() async throws {
        let book = try await BookDocumentLoader.load(fixture("ordered.epub"))
        XCTAssertEqual(book.title, "测试书")
        XCTAssertEqual(book.author, "测试作者")
        XCTAssertTrue(book.text.contains("春天 & 花朵"))
        XCTAssertFalse(book.text.contains("不应出现"))
        let first = try XCTUnwrap(book.text.range(of: "第一章"))
        let second = try XCTUnwrap(book.text.range(of: "第二章"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[1].offset, book.text.distance(from: book.text.startIndex, to: second.lowerBound))
        let chapterStart = book.text.index(book.text.startIndex, offsetBy: book.chapters[1].offset)
        XCTAssertTrue(book.text[chapterStart...].hasPrefix("第二章"))
    }
    func testEPUBTypographyDoesNotRequireExternalDTD() async throws {
        let book = try await BookDocumentLoader.load(fixture("typography.epub"))
        XCTAssertTrue(book.text.contains("“春天”"))
        XCTAssertTrue(book.text.contains("—"))
        XCTAssertFalse(book.text.contains("\u{00a0}"))
        XCTAssertTrue(book.text.contains(" "))
    }
    func testBrokenEPUBFailsInsteadOfImportingEmptyBook() async throws {
        do { _ = try await BookDocumentLoader.load(fixture("broken.epub")); XCTFail("Expected an error") } catch { }
    }
    func testPaginationPreservesAllCharactersAndResumeAfterFontChange() async throws {
        let text = String(repeating: "春天到了。👨‍👩‍👧‍👦花开了！\n", count: 900)
        let small = BookPagination.pages(text, fontSize: 14)
        let large = BookPagination.pages(text, fontSize: 30)
        XCTAssertEqual(small.map(\.text).joined(), text)
        XCTAssertEqual(large.map(\.text).joined(), text)
        let offset = small[3].offset
        let resumed = BookPagination.pageIndex(for: offset, in: large)
        XCTAssertLessThanOrEqual(large[resumed].offset, offset)
        XCTAssertGreaterThan(large[resumed].offset + large[resumed].text.utf16.count, offset)
        XCTAssertTrue(BookPagination.pages("", fontSize: 19).isEmpty)
    }
}

#if canImport(CoreText)
import CoreText

extension BookDocumentTests {
    func testScreenPaginationFitsWithoutDroppingText() async throws {
        let text = String(repeating: "春天来了。👨‍👩‍👧‍👦一起读书！\n\nA long English sentence to wrap across lines.\n", count: 100)
        for size in [CGSize(width: 320, height: 480), CGSize(width: 393, height: 650)] {
            for font in [19.0, 30.0] {
                let pages = try ScreenPagination.pages(text, size: size, fontSize: font, lineSpacing: 8)
                XCTAssertGreaterThan(pages.count, 1)
                XCTAssertEqual(pages.map(\.text).joined(), text)
                var offset = 0
                for page in pages {
                    XCTAssertEqual(page.offset, offset)
                    let rect = CGRect(x: 0, y: 0, width: size.width - 48, height: size.height - 40)
                    let frame = ScreenPagination.frame(ScreenPagination.attributed(page.text, fontSize: font, lineSpacing: 8), rect: rect)
                    XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, (page.text as NSString).length)
                    offset += page.text.utf16.count
                }
            }
        }
    }
}
#endif

extension BookDocumentTests {
    func testParsedBookCacheSurvivesReopenAndRejectsStaleOrBrokenData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let book = root.appendingPathComponent("book.txt")
        try "第一章 缓存正文".write(to: book, atomically: true, encoding: .utf8)
        let first = try await BookDocumentStore.load(book, directory: cache)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("book.txt.parsed").path))
        let actual1 = try await BookDocumentStore.load(book, directory: cache).text
        XCTAssertEqual(actual1, first.text)
        try "第二章 修改后必须读取新的正文".write(to: book, atomically: true, encoding: .utf8)
        let actual2 = try await BookDocumentStore.load(book, directory: cache).text
        XCTAssertEqual(actual2, "第二章 修改后必须读取新的正文")
        try Data("broken".utf8).write(to: cache.appendingPathComponent("book.txt.parsed"))
        let actual3 = try await BookDocumentStore.load(book, directory: cache).text
        XCTAssertEqual(actual3, "第二章 修改后必须读取新的正文")
    }
}
