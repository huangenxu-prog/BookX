import Foundation
#if canImport(ReadiumZIPFoundation)
import ReadiumZIPFoundation
#else
import ZIPFoundation
#endif
import UIKit

enum EPUBReaderError: LocalizedError {
    case invalidArchive
    case missingPackage
    case missingChapters
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "EPUB 文件无法解压或已损坏。"
        case .missingPackage: return "EPUB 缺少有效的目录信息。"
        case .missingChapters: return "EPUB 中没有可读取的正文。"
        }
    }
}

enum EPUBReader {
    static func read(url: URL) throws -> String {
        guard let archive = Archive(url: url, accessMode: .read) else { throw EPUBReaderError.invalidArchive }
        func data(at path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var bytes = Data()
            do {
                _ = try archive.extract(entry, consumer: { chunk in bytes.append(chunk) })
                return bytes
            } catch { return nil }
        }
        guard let container = data(at: "META-INF/container.xml"),
              let xml = String(data: container, encoding: .utf8),
              let rootPath = capture(xml, pattern: "full-path\\s*=\\s*[\"']([^\"']+)[\"']") else {
            throw EPUBReaderError.missingPackage
        }
        guard let opf = data(at: rootPath),
              let package = String(data: opf, encoding: .utf8) else { throw EPUBReaderError.missingPackage }
        let folder = (rootPath as NSString).deletingLastPathComponent
        var hrefByID: [String: String] = [:]
        let itemPattern = "<(?:[A-Za-z0-9_-]+:)?item\\b[^>]*>"
        for tag in matches(package, pattern: itemPattern) {
            if let id = capture(tag, pattern: "\\bid\\s*=\\s*[\"']([^\"']+)[\"']"),
               let href = capture(tag, pattern: "\\bhref\\s*=\\s*[\"']([^\"']+)[\"']") {
                hrefByID[id] = href
            }
        }
        let refs = matches(package, pattern: "<(?:[A-Za-z0-9_-]+:)?itemref\\b[^>]*>")
            .compactMap { capture($0, pattern: "idref\\s*=\\s*[\"']([^\"']+)[\"']") }
        let chapterPaths = refs.compactMap { hrefByID[$0] }
        guard !chapterPaths.isEmpty else { throw EPUBReaderError.missingChapters }
        var chapters: [String] = []
        for href in chapterPaths {
            let clean = href.removingPercentEncoding ?? href
            let path = ((folder.isEmpty ? "" : folder + "/") + clean).split(separator: "/").reduce(into: [String]()) { parts, part in
                if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                else if part != "." { parts.append(String(part)) }
            }.joined(separator: "/")
            guard let bytes = data(at: path),
                  let html = String(data: bytes, encoding: .utf8) else { continue }
            let text = htmlToText(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(text)
            }
        }
        guard !chapters.isEmpty else { throw EPUBReaderError.missingChapters }
        return chapters.joined(separator: "\n\n")
    }

    private static func htmlToText(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        let separated = withoutScripts.replacingOccurrences(of: "(?i)</?(p|div|h[1-6]|li|br|section|article)\\b[^>]*>", with: "\n", options: .regularExpression)
        let plain = separated.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        var result = plain
        for (entity, replacement) in entities { result = result.replacingOccurrences(of: entity, with: replacement) }
        return result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    private static func capture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
