import Foundation
import CoreFoundation
import ZIPFoundation

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

struct EPUBResource: Codable, Sendable { let path: String }
struct EPUBResourceIndex: Codable, Sendable {
    let title: String
    let author: String
    let resources: [EPUBResource]
}

/// Reads EPUB entries in memory; archive paths are never written to disk.
enum BookDocumentLoader {
    static func load(_ url: URL) throws -> BookDocument {
        if url.pathExtension.lowercased() == "epub" { return try epub(url) }
        let data = try Data(contentsOf: url)
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
        return BookDocument(text: text.replacingOccurrences(of: "\r\n", with: "\n"))
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
    static func epubIndex(_ url: URL) throws -> EPUBResourceIndex {
        let archive = try Archive(url: url, accessMode: .read)
        func extract(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file,
                  entry.uncompressedSize <= 4 * 1024 * 1024 else {
                throw BookReadError.invalid("EPUB 目录文件缺失或过大。")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return data
        }
        let container = EPUBXML()
        try container.parse(extract("META-INF/container.xml"))
        guard let package = container.packagePath else {
            throw BookReadError.invalid("EPUB 未包含有效的书籍目录。")
        }
        let opf = EPUBXML()
        try opf.parse(extract(package))
        let base = URL(fileURLWithPath: "/" + package).deletingLastPathComponent()
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
            return EPUBResource(path: String(path.dropFirst()))
        }
        return EPUBResourceIndex(title: opf.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 author: opf.author.trimmingCharacters(in: .whitespacesAndNewlines),
                                 resources: resources)
    }

    /// Extract a single spine resource without parsing the rest of the book.
    static func epubChapter(_ url: URL, resource: EPUBResource) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[resource.path], entry.type == .file,
              entry.uncompressedSize <= 16 * 1024 * 1024 else {
            throw BookReadError.invalid("EPUB 章节缺失或过大。")
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let chapter = EPUBXML()
        try chapter.parse(data, body: true)
        return normalizeReadingText(chapter.bodyText)
    }

    private static func epub(_ url: URL) throws -> BookDocument {
        let archive = try Archive(url: url, accessMode: .read)
        var totalBytes = 0
        func read(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file else {
                throw BookReadError.invalid("EPUB 缺少文件：\(path)")
            }
            guard entry.uncompressedSize <= 16 * 1024 * 1024 else {
                throw BookReadError.invalid("EPUB 单个章节过大。")
            }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                totalBytes += chunk.count
                guard totalBytes <= 64 * 1024 * 1024 else {
                    throw BookReadError.invalid("EPUB 正文超过当前支持的大小。")
                }
                data.append(chunk)
            }
            return data
        }
        let container = EPUBXML()
        try container.parse(read("META-INF/container.xml"))
        guard let package = container.packagePath else {
            throw BookReadError.invalid("EPUB 未包含有效的书籍目录。")
        }
        let opf = EPUBXML()
        try opf.parse(read(package))
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
            try chapter.parse(read(String(path.dropFirst())), body: true)
            let text = normalizeReadingText(chapter.bodyText)
            if !text.isEmpty {
                let heading = chapter.heading.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "第\(sections.count + 1)章"
                if !sections.isEmpty { characterOffset += 2 }
                chapters.append(BookChapter(title: heading.isEmpty ? fallback : String(heading.prefix(80)), offset: characterOffset))
                sections.append(text)
                characterOffset += text.count
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
    private var headingDepth = 0
    private var elements: [String] = []
    private var readingBody = false
    private var bodyOnly = false
    private var ignoredDepth = 0
    private var bodyFragments: [String] = []
    private var lastWasNewline = false

    func parse(_ data: Data, body: Bool = false) throws {
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
        guard parser.parse() else {
            throw BookReadError.invalid("EPUB 目录或章节格式损坏，无法读取。")
        }
        if bodyOnly { bodyText = bodyFragments.joined() }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements.append(name)
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
}

enum BookPagination {
    static func pages(_ text: String, fontSize: Double) -> [ReadingPage] {
        let length = max(250, Int(800 * 19 / fontSize))
        var result: [ReadingPage] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            let target = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
            var end = target
            if target != text.endIndex,
               let boundary = text[start..<target].lastIndex(where: { "\n。！？".contains($0) }),
               text.distance(from: start, to: boundary) > length / 2 {
                end = text.index(after: boundary)
            }
            let page = String(text[start..<end])
            result.append(ReadingPage(offset: offset, text: page))
            offset += page.count
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
        let meta = Metadata(version: 2, source: source, size: size, modified: modified,
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
    static func load(_ url: URL, directory: URL? = nil) throws -> BookDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date
        let source = url.standardizedFileURL.path
        let target = cacheURL(for: url, directory: directory)
        if let data = try? Data(contentsOf: target, options: .mappedIfSafe) {
            if let meta = try? PropertyListDecoder().decode(Metadata.self, from: data),
               meta.version == 2, meta.source == source, meta.size == size,
               meta.modified == modified,
               let body = try? Data(contentsOf: target.appendingPathExtension("txt"),
                                    options: .mappedIfSafe),
               let text = String(data: body, encoding: .utf8) {
                return BookDocument(title: meta.title, author: meta.author,
                                    text: text, chapters: meta.chapters)
            }
            // Transparently migrate already-imported books from the old single-blob cache.
            if let legacy = try? PropertyListDecoder().decode(LegacyEntry.self, from: data),
               legacy.version == 1, legacy.source == source, legacy.size == size,
               legacy.modified == modified {
                write(legacy.document, to: target, source: source, size: size, modified: modified)
                return legacy.document
            }
        }
        let document = try BookDocumentLoader.load(url)
        write(document, to: target, source: source, size: size, modified: modified)
        return document
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
              entry.version == 1, entry.sourceSize == signature.0,
              entry.modified == signature.1, entry.layoutKey == key,
              !entry.pages.isEmpty else { return nil }
        return entry.pages
    }
    static func save(_ pages: [ReadingPage], source: URL, key: String) {
        guard let signature = try? signature(source) else { return }
        let entry = Entry(version: 1, sourceSize: signature.0, modified: signature.1,
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
