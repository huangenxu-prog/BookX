import XCTest
#if canImport(BookXCore)
@testable import BookXCore
#else
@testable import BookX
#endif

final class StructuredTextTests: XCTestCase {
    private func load(_ content: String, extension ext: String) async throws -> BookDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await BookDocumentLoader.load(url)
    }

    func testMarkdownAliasesAndUnicodeTOC() async throws {
        for ext in ["md", "markdown", "MD"] {
            let book = try await load("# 第一章\n\n**正文**与[链接](https://example.invalid)。😀\n\n## 第二章\n\n- 列表项目\n\n```swift\nlet x = 1\n```", extension: ext)
            XCTAssertEqual(book.chapters.map(\.title), ["第一章", "第二章"])
            XCTAssertTrue(book.text.contains("正文与链接。😀"))
            XCTAssertFalse(book.text.contains("https://"))
            XCTAssertFalse(book.text.contains("**"))
            XCTAssertTrue(book.text.contains("列表项目"))
            XCTAssertTrue(book.text.contains("let x = 1"))
            for chapter in book.chapters {
                XCTAssertTrue((book.text as NSString).substring(from: chapter.offset).hasPrefix(chapter.title))
            }
        }
    }

    func testHTMLAliasesStructureEntitiesAndNoExecutableContent() async throws {
        for ext in ["html", "htm"] {
            let book = try await load("<html><head><title>书名</title><style>HIDDEN_STYLE</style></head><body><h1>第一章😀</h1><p>正文 &amp; 图片<img src='https://example.invalid/a.png' alt='插图说明'></p><script>HIDDEN_SCRIPT</script><h2>第二章</h2><p>末段<br>换行</body>", extension: ext)
            XCTAssertEqual(book.title, "书名")
            XCTAssertTrue(book.text.contains("正文 & 图片插图说明"))
            XCTAssertTrue(book.text.contains("末段\n换行"))
            XCTAssertFalse(book.text.contains("HIDDEN"))
            XCTAssertEqual(book.chapters.count, 2)
            for chapter in book.chapters {
                XCTAssertTrue((book.text as NSString).substring(from: chapter.offset).hasPrefix(chapter.title))
            }
        }
    }

    func testRTFUsesSystemDecoder() async throws {
        let book = try await load(#"{\rtf1\ansi\deff0 Hello \b bold\b0\par Unicode: \u20013?\u25991?}"#, extension: "rtf")
        XCTAssertTrue(book.text.contains("Hello bold"))
        XCTAssertTrue(book.text.contains("中文"))
        XCTAssertFalse(book.text.contains("\\rtf"))
    }

    func testEmptyStructuredDocumentsAreRejected() async throws {
        for (ext, source) in [("html", "<script>nothing</script>"), ("md", "<!-- nothing -->")] {
            do {
                _ = try await load(source, extension: ext)
                XCTFail("Empty \(ext) must not enter the library")
            } catch { XCTAssertTrue(error is BookReadError) }
        }
    }

    func testPlainTextIsNotInterpretedAsMarkup() async throws {
        let source = "# 标题\n**正文** <script>保留</script>"
        let book = try await load(source, extension: "txt")
        XCTAssertEqual(book.text, source)
    }
}

extension StructuredTextTests {
    func testOldMarkdownCacheIsReparsed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("book.md")
        try "# 标题\n\n**正文**".write(to: url, atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent("cache")
        _ = try await BookDocumentStore.load(url, directory: cache)
        let metadataURL = cache.appendingPathComponent("book.md.parsed")
        var metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: metadataURL), format: nil) as? [String: Any])
        metadata["version"] = 3
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0).write(to: metadataURL)
        try "OLD RAW MARKDOWN".write(to: metadataURL.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        let result = try await BookDocumentStore.load(url, directory: cache)
        XCTAssertFalse(result.text.contains("OLD"))
        XCTAssertEqual(result.chapters.first?.title, "标题")
        XCTAssertTrue(result.text.contains("正文"))
    }
}
