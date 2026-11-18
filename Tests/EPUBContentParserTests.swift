import XCTest
@testable import BookXCore

final class EPUBContentParserTests: XCTestCase {
    func testKeepsImagesInReadingOrder() throws {
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

    func testRejectsRemoteImages() throws {
        let html = #"<html><body><img src="https://example.com/a.png"/><p>正文</p></body></html>"#
        XCTAssertEqual(try EPUBContentParser.blocks(Data(html.utf8), chapterPath: "text/1.xhtml"),
                       [EPUBContentBlock(kind: .text("正文"))])
    }
}
