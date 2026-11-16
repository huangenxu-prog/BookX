import Foundation
import CoreFoundation
import ZIPFoundation

struct BookDocument {
    var title: String = ""
    var author: String = ""
    var text: String
}

enum BookReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
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
            let text = chapter.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sections.append(text) }
        }
        guard !sections.isEmpty else {
            throw BookReadError.invalid("未找到可阅读的 EPUB 文字正文；暂不支持纯图片或加密书籍。")
        }
        return BookDocument(title: opf.title.trimmingCharacters(in: .whitespacesAndNewlines),
                            author: opf.author.trimmingCharacters(in: .whitespacesAndNewlines),
                            text: sections.joined(separator: "\n\n"))
    }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    var packagePath: String?
    var items: [String: (href: String, type: String)] = [:]
    var spine: [String] = []
    var title = ""
    var author = ""
    var bodyText = ""
    private var elements: [String] = []
    private var readingBody = false
    private var bodyOnly = false
    private var ignoredDepth = 0

    func parse(_ data: Data, body: Bool = false) throws {
        bodyOnly = body
        // EPUB XHTML often uses HTML entities from an external DTD. Resolve the
        // common typography locally, without fetching external resources.
        var xml = data
        if body, var text = String(data: data, encoding: .utf8) {
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
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements.append(name)
        if name == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            items[id] = (href, attributes["media-type"] ?? "")
        }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        if name == "body" { readingBody = true }
        if ignoredDepth > 0 || ["script", "style", "nav"].contains(name) { ignoredDepth += 1 }
        if bodyOnly && readingBody && ignoredDepth == 0 && ["p", "div", "br", "h1", "h2", "h3", "li"].contains(name) { newline() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if bodyOnly {
            if readingBody && ignoredDepth == 0 { bodyText += string }
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
        if name == "body" { readingBody = false }
        _ = elements.popLast()
    }
    private func newline() {
        if !bodyText.hasSuffix("\n") { bodyText += "\n" }
    }
}

struct ReadingPage {
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
        pages.lastIndex(where: { $0.offset <= offset }) ?? 0
    }
}
