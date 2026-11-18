import Foundation
import XCTest
@testable import BookXCore

final class FB2DocumentTests: XCTestCase {
    private func load(_ xml: String) async throws -> BookDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("fb2")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await BookDocumentLoader.load(url)
    }

    func testMetadataChapterOffsetsAndUnicodeResume() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description><title-info><book-title>测试书名</book-title>
            <author><first-name>张</first-name><last-name>三</last-name></author>
          </title-info></description>
          <body>
            <section><title><p>第一章</p></title><p>你好👨‍👩‍👧‍👦世界。</p></section>
            <section><title><p>第二章</p></title><p>继续阅读。</p></section>
          </body>
        </FictionBook>
        """
        let book = try await load(xml)
        XCTAssertEqual(book.title, "测试书名")
        XCTAssertEqual(book.author, "张三")
        XCTAssertEqual(book.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertTrue(book.text.contains("你好👨‍👩‍👧‍👦世界。"))
        for chapter in book.chapters {
            let text = book.text as NSString
            XCTAssertLessThan(chapter.offset, text.length)
            XCTAssertTrue(text.substring(from: chapter.offset).hasPrefix(chapter.title))
        }
        let pages = BookPagination.pages(book.text, fontSize: 19)
        XCTAssertEqual(pages.map(\.text).joined(), book.text)
    }

    func testRejectsMalformedOrEmptyFB2() async throws {
        for xml in ["<FictionBook><body><section>", "<FictionBook><body></body></FictionBook>"] {
            do {
                _ = try await load(xml)
                XCTFail("Expected invalid FB2 to fail")
            } catch {
                XCTAssertNotNil(error as? BookReadError)
            }
        }
    }

    func testBinaryPayloadIsNotIncludedInReadingText() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook><description><title-info><book-title>图片书</book-title></title-info></description>
          <binary id="cover" content-type="image/png">SHOULD_NOT_APPEAR</binary>
          <body><section><title><p>正文</p></title><p>正常内容</p></section></body>
        </FictionBook>
        """
        let book = try await load(xml)
        XCTAssertFalse(book.text.contains("SHOULD_NOT_APPEAR"))
        XCTAssertTrue(book.text.contains("正常内容"))
    }
    func testInlineFormattingDoesNotDiscardText() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook><body><section><title><p>第一章</p></title>
          <p>普通<strong>加粗</strong>以及<emphasis>强调</emphasis>文字。</p>
        </section></body></FictionBook>
        """
        let book = try await load(xml)
        XCTAssertTrue(book.text.contains("普通加粗以及强调文字。"))
    }

}
