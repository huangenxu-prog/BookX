import XCTest
@testable import BookXCore

final class EPUBContentParserTests: XCTestCase {
    func testKeepsImagesInReadingOrder() async throws {
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>第一段</p><img src="../Images/map%201.png" alt="地图"/>
        <p>第二段</p><script>bad()</script>
        </body></html>
        """
        let blocks = try EPUBContentParser.blocks(Data(html.utf8), chapterPath: "OEBPS/Text/ch01.xhtml")
        XCTAssertEqual(blocks, [
            EPUBContentBlock(kind: .text("第一段")),
            EPUBContentBlock(kind: .image(path: "OEBPS/Images/map 1.png", alternative: "地图")),
            EPUBContentBlock(kind: .text("第二段"))
        ])
    }

    func testRejectsRemoteImages() async throws {
        let html = #"<html><body><img src="https://example.com/a.png"/><p>正文</p></body></html>"#
        XCTAssertEqual(try EPUBContentParser.blocks(Data(html.utf8), chapterPath: "text/1.xhtml"),
                       [EPUBContentBlock(kind: .text("正文"))])
    }
    func testIllustratedEPUBIndexAndImageExtraction() async throws {
        let original = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/illustrated.epub"))
        let index = try await BookDocumentLoader.epubIndex(original)
        XCTAssertEqual(index.resources.count, 1)
        let richBlocks = try await BookDocumentLoader.epubBlocks(original, resource: index.resources[0])
        XCTAssertEqual(richBlocks, [
            EPUBContentBlock(kind: .text("图前文字")),
            EPUBContentBlock(kind: .image(path: "OPS/Images/figure 1.png", alternative: "插图")),
            EPUBContentBlock(kind: .text("图后文字"))
        ])
        let blocks = try EPUBContentParser.blocks(
            Data("<html><body><p>图前文字</p><img src=\"../Images/figure%201.png\"/><p>图后文字</p></body></html>".utf8),
            chapterPath: index.resources[0].path)
        XCTAssertEqual(blocks.count, 3)
        guard case let .image(path, _) = blocks[1].kind else {
            return XCTFail("Image block missing")
        }
        let image = try await BookDocumentLoader.epubImageData(original, path: path)
        XCTAssertTrue(image.starts(with: [137, 80, 78, 71]))
        do { _ = try await BookDocumentLoader.epubImageData(original, path: "../outside.png"); XCTFail("Expected an error") } catch { }
    }

}
