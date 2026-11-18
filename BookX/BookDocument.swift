import Foundation
import CoreFoundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BookChapter: Codable, Sendable {
    let title: String
    let offset: Int
}

struct BookDocument: Codable, Sendable {
    var title: String = ""
    var author: String = ""
    var text: String
    var chapters: [BookChapter] = []
}

enum BookReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct EPUBResource: Codable, Sendable { let path: String; var title: String? = nil }
struct EPUBResourceIndex: Codable, Sendable {
    let title: String
    let author: String
    let resources: [EPUBResource]
}

/// Reads EPUB entries in memory; archive paths are never written to disk.
enum BookDocumentLoader {
    static func load(_ url: URL) async throws -> BookDocument {
        if url.pathExtension.lowercased() == "epub" { return try await epub(url) }
        let ext = url.pathExtension.lowercased()
        let limit = ext == "rtf" ? 20 * 1024 * 1024 : 50 * 1024 * 1024
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= limit else { throw BookReadError.invalid("文件过大，当前格式上限为 \(limit / 1024 / 1024) MB。") }
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        if ext == "fb2" { return try FB2TextReader.parse(data) }
        if ext == "rtf" {
            guard data.count <= 20 * 1024 * 1024 else {
                throw BookReadError.invalid("RTF 文件超过 20 MB。")
            }
            let attributed = try NSAttributedString(data: data, options: [
                .documentType: NSAttributedString.DocumentType.rtf
            ], documentAttributes: nil)
            let body = attributed.string.replacingOccurrences(of: "\u{fffc}", with: "")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BookReadError.invalid("RTF 正文为空。")
            }
            return BookDocument(text: body)
        }
        guard data.count <= 50 * 1024 * 1024 else {
            throw BookReadError.invalid("文件过大，请导入小于 50 MB 的 TXT。")
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        // Only try UTF-16 when a BOM exists; arbitrary GB bytes can otherwise decode as gibberish.
        let bytes = Array(data.prefix(3))
        let encodings: [String.Encoding] = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
            ? [.utf16] : [.utf8, gb]
        guard let text = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookReadError.invalid("正文为空或无法识别文字编码。")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let result: BookDocument
        switch ext {
        case "md", "markdown": result = try StructuredTextReader.markdown(normalized)
        case "html", "htm": result = try StructuredTextReader.html(normalized)
        default: result = BookDocument(text: normalized)
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookReadError.invalid("文件没有可读取的文字正文。")
        }
        return result
    }

    private static let normalizationRules: [(NSRegularExpression, String)] = [
        (#"[\x{00A0}\x{2002}\x{2003}\x{3000}\t]+"#, " "),
        (#" *\n *"#, "\n"),
        (#"\n{3,}"#, "\n\n")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func normalizeReadingText(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        for (expression, replacement) in normalizationRules {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read only EPUB package metadata and its spine. No chapter XHTML is decompressed.
    /// This is the first stage of resource-oriented, on-demand EPUB loading.
    static func epubIndex(_ url: URL) async throws -> EPUBResourceIndex {
        let archive = try await EPUBArchive(url: url)
        func extract(_ path: String) async throws -> Data {
            try await archive.read(path, limit: 4 * 1024 * 1024)
        }
        let container = EPUBXML()
        try container.parse(await extract("META-INF/container.xml"))
        guard let package = container.packagePath else {
            throw BookReadError.invalid("EPUB 未包含有效的书籍目录。")
        }
        let opf = EPUBXML()
        try opf.parse(await extract(package))
        let base = URL(fileURLWithPath: "/" + package).deletingLastPathComponent()
        var names: [String: String] = [:]
        if let nav = opf.navigationPath ?? opf.items.values.first(where: { $0.type == "application/x-dtbncx+xml" })?.href {
            let navURL = base.appendingPathComponent(nav.removingPercentEncoding ?? nav).standardizedFileURL
            let navigator = EPUBXML()
            if let bytes = try? await extract(String(navURL.path.dropFirst())), (try? navigator.parse(bytes)) != nil {
                for (href, title) in navigator.navigationTitles {
                    let relative = String(href.split(separator: "#", maxSplits: 1).first ?? "")
                    let path = navURL.deletingLastPathComponent().appendingPathComponent(relative.removingPercentEncoding ?? relative).standardizedFileURL.path
                    if names[String(path.dropFirst())] == nil { names[String(path.dropFirst())] = title }
                }
            }
        }
        let resources: [EPUBResource] = try opf.spine.compactMap { id in
            guard let item = opf.items[id] else {
                throw BookReadError.invalid("EPUB 阅读顺序引用了不存在的章节。")
            }
            guard item.type == "application/xhtml+xml" || item.type == "text/html" else { return nil }
            let href = String(item.href.split(separator: "#", maxSplits: 1).first ?? "")
            guard !href.contains("://"), !href.hasPrefix("/") else {
                throw BookReadError.invalid("EPUB 章节地址无效。")
            }
            let path = base.appendingPathComponent(href.removingPercentEncoding ?? href)
                .standardizedFileURL.path
            return EPUBResource(path: String(path.dropFirst()), title: names[String(path.dropFirst())])
        }
        guard !resources.isEmpty else { throw BookReadError.invalid("EPUB 没有可阅读的文字章节。") }
        return EPUBResourceIndex(title: opf.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 author: opf.author.trimmingCharacters(in: .whitespacesAndNewlines),
                                 resources: resources)
    }

    /// Load a referenced illustration on demand. Never expand the whole EPUB or
    /// follow external URLs. The caller owns image decoding and display sizing.
    static func epubImageData(_ url: URL, path: String) async throws -> Data {
        try Task.checkCancellation()
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("://"),
              !path.split(separator: "/").contains("..") else {
            throw BookReadError.invalid("EPUB 图片地址无效。")
        }
        let archive = try await EPUBArchive(url: url)
        return try await archive.read(path, limit: 20 * 1024 * 1024)
    }

    /// Preserve the ordered XHTML blocks for the rich EPUB renderer.
    /// This intentionally does not alter the legacy plain-text reading path.
    static func epubBlocks(_ url: URL, resource: EPUBResource) async throws -> [EPUBContentBlock] {
        try Task.checkCancellation()
        let archive = try await EPUBArchive(url: url)
        let data = try await archive.read(resource.path, limit: 16 * 1024 * 1024)
        return try EPUBContentParser.blocks(data, chapterPath: resource.path)
    }

    /// Extract a single spine resource without parsing the rest of the book.
    static func epubChapter(_ url: URL, resource: EPUBResource) async throws -> String {
        let archive = try await EPUBArchive(url: url)
        let data = try await archive.read(resource.path, limit: 16 * 1024 * 1024)
        let chapter = EPUBXML()
        try chapter.parse(data, body: true)
        return normalizeReadingText(chapter.bodyText)
    }

    private static func epub(_ url: URL) async throws -> BookDocument {
        let archive = try await EPUBArchive(url: url)
        var totalBytes = 0
        func read(_ path: String) async throws -> Data {
            let data = try await archive.read(path, limit: 16 * 1024 * 1024)
            totalBytes += data.count
            guard totalBytes <= 64 * 1024 * 1024 else {
                throw BookReadError.invalid("EPUB 正文超过当前支持的大小。")
            }
            return data
        }
        let container = EPUBXML()
        try container.parse(await read("META-INF/container.xml"))
        guard let package = container.packagePath else {
            throw BookReadError.invalid("EPUB 未包含有效的书籍目录。")
        }
        let opf = EPUBXML()
        try opf.parse(await read(package))
        let base = URL(fileURLWithPath: "/" + package).deletingLastPathComponent()
        var sections: [String] = []
        var chapters: [BookChapter] = []
        var characterOffset = 0
        for id in opf.spine {
            guard let item = opf.items[id] else {
                throw BookReadError.invalid("EPUB 阅读顺序引用了不存在的章节。")
            }
            guard item.type == "application/xhtml+xml" || item.type == "text/html" else { continue }
            let href = String(item.href.split(separator: "#", maxSplits: 1).first ?? "")
            guard !href.contains("://"), !href.hasPrefix("/") else {
                throw BookReadError.invalid("EPUB 章节地址无效。")
            }
            let path = base.appendingPathComponent(href.removingPercentEncoding ?? href).standardizedFileURL.path
            let chapter = EPUBXML()
            try chapter.parse(await read(String(path.dropFirst())), body: true)
            let text = normalizeReadingText(chapter.bodyText)
            if !text.isEmpty {
                let heading = chapter.heading.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "第\(sections.count + 1)章"
                if !sections.isEmpty { characterOffset += 2 }
                chapters.append(BookChapter(title: heading.isEmpty ? fallback : String(heading.prefix(80)), offset: characterOffset))
                sections.append(text)
                characterOffset += text.utf16.count
            }
        }
        guard !sections.isEmpty else {
            throw BookReadError.invalid("未找到可阅读的 EPUB 文字正文；暂不支持纯图片或加密书籍。")
        }
        return BookDocument(title: opf.title.trimmingCharacters(in: .whitespacesAndNewlines),
                            author: opf.author.trimmingCharacters(in: .whitespacesAndNewlines),
                            text: sections.joined(separator: "\n\n"), chapters: chapters)
    }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    var packagePath: String?
    var items: [String: (href: String, type: String)] = [:]
    var spine: [String] = []
    var title = ""
    var author = ""
    var bodyText = ""
    var heading = ""
    var navigationPath: String?
    var navigationTitles: [(String, String)] = []
    private var navPoints: [(href: String, title: String)] = []
    private var anchorHref: String?
    private var anchorText = ""
    private var headingDepth = 0
    private var elements: [String] = []
    private var readingBody = false
    private var bodyOnly = false
    private var ignoredDepth = 0
    private var bodyFragments: [String] = []
    private var lastWasNewline = false

    func parse(_ data: Data, body: Bool = false) throws {
        try Task.checkCancellation()
        bodyOnly = body
        // EPUB XHTML often uses HTML entities from an external DTD. Resolve the
        // common typography locally, without fetching external resources.
        var xml = data
        if body, var text = String(data: data, encoding: .utf8), text.contains("&") {
            let entities = ["nbsp": 160, "ensp": 8194, "emsp": 8195, "thinsp": 8201,
                            "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217,
                            "ldquo": 8220, "rdquo": 8221, "hellip": 8230, "bull": 8226,
                            "middot": 183, "copy": 169, "reg": 174, "trade": 8482]
            for (name, code) in entities {
                text = text.replacingOccurrences(of: "&\(name);", with: "&#\(code);")
            }
            xml = Data(text.utf8)
        }
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let succeeded = parser.parse()
        try Task.checkCancellation()
        guard succeeded else {
            throw BookReadError.invalid("EPUB 目录或章节格式损坏，无法读取。")
        }
        if bodyOnly { bodyText = bodyFragments.joined() }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { parser.abortParsing(); return }
        elements.append(name)
        if !bodyOnly {
            if name == "item", attributes["properties"]?.split(separator: " ").contains("nav") == true { navigationPath = attributes["href"] }
            if name == "navPoint" { navPoints.append(("", "")) }
            if name == "content", let href = attributes["src"], !navPoints.isEmpty { navPoints[navPoints.count - 1].href = href }
            if name == "a" { anchorHref = attributes["href"]; anchorText = "" }
        }
        if name == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            items[id] = (href, attributes["media-type"] ?? "")
        }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        if name == "body" { readingBody = true }
        if bodyOnly && readingBody && heading.isEmpty && ["h1", "h2", "h3"].contains(name) { headingDepth = elements.count }
        if ignoredDepth > 0 || ["script", "style", "nav"].contains(name) { ignoredDepth += 1 }
        if bodyOnly && readingBody && ignoredDepth == 0 && ["p", "div", "br", "h1", "h2", "h3", "li"].contains(name) { newline() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        if !bodyOnly {
            if !navPoints.isEmpty && elements.contains("navLabel") { navPoints[navPoints.count - 1].title += string }
            if anchorHref != nil { anchorText += string }
        }
        if bodyOnly {
            if readingBody && ignoredDepth == 0 {
                if headingDepth > 0 && heading.count < 100 { heading += string }
                bodyFragments.append(string)
                lastWasNewline = string.hasSuffix("\n")
            }
        } else if elements.contains("metadata") {
            if elements.last == "title" { title += string }
            if elements.last == "creator" { author += string }
        }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !bodyOnly {
            if name == "navPoint", let item = navPoints.popLast(), !item.href.isEmpty {
                navigationTitles.append((item.href, item.title.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if name == "a", let href = anchorHref {
                navigationTitles.append((href, anchorText.trimmingCharacters(in: .whitespacesAndNewlines)))
                anchorHref = nil
            }
        }
        if bodyOnly && readingBody && ignoredDepth == 0 && ["p", "div", "h1", "h2", "h3", "li"].contains(name) { newline() }
        if ignoredDepth > 0 { ignoredDepth -= 1 }
        if headingDepth == elements.count { headingDepth = 0 }
        if name == "body" { readingBody = false }
        _ = elements.popLast()
    }
    private func newline() {
        if !lastWasNewline { bodyFragments.append("\n"); lastWasNewline = true }
    }
}

struct ReadingPage: Codable, Sendable {
    let offset: Int
    let text: String
    var resourceIndex: Int? = nil
    // A standalone illustration sheet keeps the native page-curl architecture.
    // This is deliberately optional so TXT and existing cached text pages decode unchanged.
    var imagePath: String? = nil
}

enum BookPagination {
    static func pages(_ text: String, fontSize: Double) -> [ReadingPage] {
        let length = max(250, Int(800 * 19 / fontSize))
        var result: [ReadingPage] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            if Task.isCancelled { return [] }
            let target = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
            var end = target
            if target != text.endIndex,
               let boundary = text[start..<target].lastIndex(where: { "\n。！？".contains($0) }),
               text.distance(from: start, to: boundary) > length / 2 {
                end = text.index(after: boundary)
            }
            let page = String(text[start..<end])
            result.append(ReadingPage(offset: offset, text: page))
            offset += page.utf16.count
            start = end
        }
        return result
    }
    static func pageIndex(for offset: Int, in pages: [ReadingPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var low = 0
        var high = pages.count
        while low < high {
            let mid = low + (high - low) / 2
            if pages[mid].offset <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
}

/// Readium-style resource access: persist the spine index, then load individual XHTML
/// resources on demand. This cache never changes the original EPUB.
enum EPUBResourceStore {
    private struct IndexEntry: Codable {
        let version: Int
        let sourceSize: Int
        let modified: Date?
        let source: String
        let index: EPUBResourceIndex
    }
    private static func key(_ source: URL) -> String {
        SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private struct ChapterEntry: Codable {
        let version: Int
        let identity: String
        let text: String
    }
    private static func indexURL(_ source: URL) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookXSpines", isDirectory: true)
            .appendingPathComponent(key(source) + ".plist")
    }
    private static func signature(_ source: URL) throws -> (Int, Date?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        return ((attributes[.size] as? NSNumber)?.intValue ?? 0,
                attributes[.modificationDate] as? Date)
    }
    static func index(_ source: URL) async throws -> EPUBResourceIndex {
        try Task.checkCancellation()
        let (size, modified) = try signature(source)
        let target = indexURL(source)
        if let data = try? Data(contentsOf: target),
           let cached = try? PropertyListDecoder().decode(IndexEntry.self, from: data),
           cached.version == 4, cached.source == source.standardizedFileURL.path, cached.sourceSize == size, cached.modified == modified {
            return cached.index
        }
        let result: EPUBResourceIndex
        #if canImport(ReadiumStreamer)
        do {
            result = try await ReadiumPublicationStore.shared.index(source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Historical, malformed books can still use the existing reader.
            result = try await BookDocumentLoader.epubIndex(source)
        }
        #else
        result = try await BookDocumentLoader.epubIndex(source)
        #endif
        let entry = IndexEntry(version: 4, sourceSize: size, modified: modified, source: source.standardizedFileURL.path, index: result)
        if let data = try? PropertyListEncoder().encode(entry) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
        return result
    }
    private static func chapterURL(_ source: URL, position: Int) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookXChapters", isDirectory: true)
            .appendingPathComponent(key(source), isDirectory: true)
        return root.appendingPathComponent("\(position).plist")
    }
    static func chapter(_ source: URL, index: EPUBResourceIndex, at position: Int) async throws -> String {
        guard index.resources.indices.contains(position) else {
            throw BookReadError.invalid("章节位置超出 EPUB 阅读顺序。")
        }
        try Task.checkCancellation()
        let target = chapterURL(source, position: position)
        let stamp = try signature(source)
        let identity = source.standardizedFileURL.path + "|\(stamp.0)|\(stamp.1?.timeIntervalSince1970 ?? 0)|" + index.resources[position].path
        if let data = try? Data(contentsOf: target),
           let cached = try? PropertyListDecoder().decode(ChapterEntry.self, from: data),
           cached.version == 1, cached.identity == identity { return cached.text }
        let text = try await BookDocumentLoader.epubChapter(source, resource: index.resources[position])
        try Task.checkCancellation()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(ChapterEntry(version: 1, identity: identity, text: text)) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Publish payload and source identity in one atomic write; concurrent readers
            // can never observe a new marker beside an old chapter body.
            try? data.write(to: target, options: .atomic)
        }
        return text
    }
    static func remove(_ source: URL) {
        try? FileManager.default.removeItem(at: indexURL(source))
        try? FileManager.default.removeItem(at: chapterURL(source, position: 0).deletingLastPathComponent())
    }
}

/// Disposable parsed-book cache. Original files remain the source of truth.
enum BookDocumentStore {
    // Keep large book text out of property-list decoding. The metadata is small;
    // the UTF-8 body can be memory-mapped by Foundation on repeated opens.
    private struct Metadata: Codable {
        let version: Int
        let source: String
        let size: Int
        let modified: Date?
        let title: String
        let author: String
        let chapters: [BookChapter]
    }
    private struct LegacyEntry: Codable {
        let version: Int
        let source: String
        let size: Int
        let modified: Date?
        let document: BookDocument
    }
    private static func cacheURL(for url: URL, directory: URL?) -> URL {
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookXDocuments", isDirectory: true)
        return root.appendingPathComponent(url.lastPathComponent + ".parsed")
    }
    private static func write(_ document: BookDocument, to target: URL,
                              source: String, size: Int, modified: Date?) {
        let meta = Metadata(version: 4, source: source, size: size, modified: modified,
                            title: document.title, author: document.author,
                            chapters: document.chapters)
        let textURL = target.appendingPathExtension("txt")
        guard let info = try? PropertyListEncoder().encode(meta),
              let body = document.text.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        // Write the text first, then publish metadata as the completion marker.
        guard (try? body.write(to: textURL, options: .atomic)) != nil else { return }
        try? info.write(to: target, options: .atomic)
    }
    static func load(_ url: URL, directory: URL? = nil) async throws -> BookDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date
        let source = url.standardizedFileURL.path
        let target = cacheURL(for: url, directory: directory)
        if let data = try? Data(contentsOf: target, options: .mappedIfSafe) {
            if let meta = try? PropertyListDecoder().decode(Metadata.self, from: data),
               meta.version == 4, meta.source == source, meta.size == size,
               meta.modified == modified,
               let body = try? Data(contentsOf: target.appendingPathExtension("txt"),
                                    options: .mappedIfSafe),
               let text = String(data: body, encoding: .utf8) {
                return BookDocument(title: meta.title, author: meta.author,
                                    text: text, chapters: meta.chapters)
            }
            // Transparently migrate already-imported books from the old single-blob cache.
            if let legacy = try? PropertyListDecoder().decode(LegacyEntry.self, from: data),
               legacy.version == 1, !["md", "markdown", "rtf", "html", "htm"].contains(url.pathExtension.lowercased()),
               legacy.source == source, legacy.size == size,
               legacy.modified == modified {
                write(legacy.document, to: target, source: source, size: size, modified: modified)
                return legacy.document
            }
        }
        let document = try await BookDocumentLoader.load(url)
        write(document, to: target, source: source, size: size, modified: modified)
        return document
    }
    static func cachedChapters(_ url: URL) -> [BookChapter]? {
        guard let data = try? Data(contentsOf: cacheURL(for: url, directory: nil)),
              let meta = try? PropertyListDecoder().decode(Metadata.self, from: data),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              meta.version == 4, meta.source == url.standardizedFileURL.path,
              meta.size == (attributes[.size] as? NSNumber)?.intValue,
              meta.modified == (attributes[.modificationDate] as? Date) else { return nil }
        return meta.chapters
    }
    static func remove(_ url: URL) {
        let target = cacheURL(for: url, directory: nil)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: target.appendingPathExtension("txt"))
    }
}

/// Disk-backed pagination cache, keyed by the original file and exact reading geometry.
/// A cached layout avoids repeating expensive Core Text measurement on every reopen.
enum BookPageStore {
    private struct Entry: Codable {
        let version: Int
        let sourceSize: Int
        let modified: Date?
        let layoutKey: String
        let pages: [ReadingPage]
    }
    private static func url(for source: URL, key: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookXPages", isDirectory: true)
        // Layout keys contain only numeric geometry, font metrics, and mode.
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent(source.lastPathComponent + "-" + safeKey + ".plist")
    }
    private static func signature(_ source: URL) throws -> (Int, Date?) {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        return ((attrs[.size] as? NSNumber)?.intValue ?? 0, attrs[.modificationDate] as? Date)
    }
    static func load(_ source: URL, key: String) -> [ReadingPage]? {
        guard let signature = try? signature(source),
              let data = try? Data(contentsOf: url(for: source, key: key)),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.version == 3, entry.sourceSize == signature.0,
              entry.modified == signature.1, entry.layoutKey == key,
              !entry.pages.isEmpty else { return nil }
        return entry.pages
    }
    static func save(_ pages: [ReadingPage], source: URL, key: String) {
        guard let signature = try? signature(source) else { return }
        let entry = Entry(version: 3, sourceSize: signature.0, modified: signature.1,
                          layoutKey: key, pages: pages)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entry) else { return }
        let target = url(for: source, key: key)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
    static func remove(_ source: URL) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookXPages", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root,
                                                includingPropertiesForKeys: nil) else { return }
        for file in entries where file.lastPathComponent.hasPrefix(source.lastPathComponent + "-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}


// FB2 is an XML-based ebook format. Keep its parsing independent of EPUB archives.
private final class FB2TextReader: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var body = ""
    private var bookTitle = ""
    private var authors: [String] = []
    private var authorParts: [String] = []
    private var chapters: [BookChapter] = []
    private var sectionDepth = 0
    private var sectionTitle = ""
    private var inSectionTitle = false
    private var inMainBody = false
    private var inAuthor = false
    private var inBookTitle = false
    private var inBinary = false

    static func parse(_ data: Data) throws -> BookDocument {
        let reader = FB2TextReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else {
            throw BookReadError.invalid("FB2 XML 解析失败：\(parser.parserError?.localizedDescription ?? "格式无效")")
        }
        let text = reader.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BookReadError.invalid("FB2 没有可读取的正文。") }
        return BookDocument(title: reader.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            author: reader.authors.joined(separator: "、"), text: text,
                            chapters: reader.chapters)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if Task.isCancelled { parser.abortParsing(); return }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elements.append(name)
        if name == "binary" { inBinary = true }
        if name == "body" && !inMainBody && attributes["name"] == nil { inMainBody = true }
        if name == "author" && elements.contains("title-info") { inAuthor = true; authorParts = [] }
        if name == "book-title" && elements.contains("title-info") { inBookTitle = true }
        if inMainBody && name == "section" { sectionDepth += 1 }
        if inMainBody && name == "title" && sectionDepth > 0 { inSectionTitle = true; sectionTitle = "" }
        if inMainBody && name == "p" && !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBinary { return }
        if inBookTitle { bookTitle += string; return }
        if inAuthor && ["first-name", "middle-name", "last-name", "nickname"].contains(elements.last ?? "") {
            authorParts.append(string)
            return
        }
        guard inMainBody else { return }
        if inSectionTitle { sectionTitle += string }
        else if ["p", "v", "subtitle", "text-author"].contains(elements.last ?? "") { body += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "binary" { inBinary = false }
        if name == "book-title" { inBookTitle = false }
        if name == "author" && inAuthor {
            let value = authorParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { authors.append(value) }
            inAuthor = false
        }
        if inMainBody && name == "title" && inSectionTitle {
            let title = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                if !body.isEmpty { body += "\n\n" }
                chapters.append(BookChapter(title: title, offset: body.utf16.count))
                body += title + "\n\n"
            }
            inSectionTitle = false
        }
        if inMainBody && ["p", "v", "subtitle", "empty-line"].contains(name) { body += "\n" }
        if inMainBody && name == "section" { sectionDepth = max(0, sectionDepth - 1) }
        if name == "body" && inMainBody { inMainBody = false }
        if !elements.isEmpty { elements.removeLast() }
    }
}
