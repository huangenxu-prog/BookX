import XCTest
@testable import BookXCore

final class BookDocumentTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
    }
    func testChineseEncodings() throws {
        let gb = try BookDocumentLoader.load(fixture("gb18030.txt"))
        XCTAssertTrue(gb.text.hasPrefix("第一章 春天"))
        XCTAssertTrue(gb.text.contains("不能误判"))
        let utf16 = try BookDocumentLoader.load(fixture("utf16.txt"))
        XCTAssertTrue(utf16.text.contains("带有字节顺序标记"))
    }
    func testEPUBMetadataSpineOrderAndEscapedPaths() throws {
        let book = try BookDocumentLoader.load(fixture("ordered.epub"))
        XCTAssertEqual(book.title, "测试书")
        XCTAssertEqual(book.author, "测试作者")
        XCTAssertTrue(book.text.contains("春天 & 花朵"))
        XCTAssertFalse(book.text.contains("不应出现"))
        let first = try XCTUnwrap(book.text.range(of: "第一章"))
        let second = try XCTUnwrap(book.text.range(of: "第二章"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }
    func testEPUBTypographyDoesNotRequireExternalDTD() throws {
        let book = try BookDocumentLoader.load(fixture("typography.epub"))
        XCTAssertTrue(book.text.contains("“春天”"))
        XCTAssertTrue(book.text.contains("—"))
        XCTAssertFalse(book.text.contains("\u{00a0}"))
        XCTAssertTrue(book.text.contains(" "))
    }
    func testBrokenEPUBFailsInsteadOfImportingEmptyBook() {
        XCTAssertThrowsError(try BookDocumentLoader.load(fixture("broken.epub")))
    }
    func testPaginationPreservesAllCharactersAndResumeAfterFontChange() {
        let text = String(repeating: "春天到了。👨‍👩‍👧‍👦花开了！\n", count: 900)
        let small = BookPagination.pages(text, fontSize: 14)
        let large = BookPagination.pages(text, fontSize: 30)
        XCTAssertEqual(small.map(\.text).joined(), text)
        XCTAssertEqual(large.map(\.text).joined(), text)
        let offset = small[3].offset
        let resumed = BookPagination.pageIndex(for: offset, in: large)
        XCTAssertLessThanOrEqual(large[resumed].offset, offset)
        XCTAssertGreaterThan(large[resumed].offset + large[resumed].text.count, offset)
        XCTAssertTrue(BookPagination.pages("", fontSize: 19).isEmpty)
    }
}
