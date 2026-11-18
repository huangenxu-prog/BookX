import Foundation
import FoundationXML

/// EPUB content is not equivalent to plain text. This intermediate representation
/// retains image placement without changing the existing pagination engine yet.
struct EPUBContentBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case image(path: String, alternative: String)
    }
    let kind: Kind
}

enum EPUBContentParser {
    static func blocks(_ data: Data, chapterPath: String) throws -> [EPUBContentBlock] {
        let parser = XMLParser(data: data)
        let delegate = Delegate(chapterPath: chapterPath)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw BookReadError.invalid("EPUB XHTML 格式不正确：\(chapterPath)")
        }
        return delegate.result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let chapterPath: String
        var result: [EPUBContentBlock] = []
        private var text = ""
        private var inBody = false
        private var ignored = 0

        init(chapterPath: String) { self.chapterPath = chapterPath }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String]) {
            if Task.isCancelled { parser.abortParsing(); return }
            let name = elementName.lowercased()
            if name == "body" { inBody = true }
            if ignored > 0 || ["script", "style", "nav"].contains(name) { ignored += 1; return }
            guard inBody else { return }
            if name == "img" || name == "image" {
                flush()
                let source = attributeDict["src"] ?? attributeDict["href"] ??
                    attributeDict["xlink:href"] ?? ""
                let alt = attributeDict["alt"] ?? ""
                if let path = resolve(source) {
                    result.append(EPUBContentBlock(kind: .image(path: path, alternative: alt)))
                }
            } else if ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inBody && ignored == 0 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if ignored > 0 { ignored -= 1; return }
            let name = elementName.lowercased()
            if inBody && ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            }
            if name == "body" { flush(); inBody = false }
        }

        private func flush() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(EPUBContentBlock(kind: .text(value))) }
            text = ""
        }

        private func resolve(_ source: String) -> String? {
            guard !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix("#"),
                  !source.contains("://"), !source.lowercased().hasPrefix("data:") else { return nil }
            let relative = String(source.split(separator: "#", maxSplits: 1).first ?? "")
            let decoded = relative.removingPercentEncoding ?? relative
            let base = URL(fileURLWithPath: "/" + chapterPath).deletingLastPathComponent()
            let resolved = base.appendingPathComponent(decoded).standardizedFileURL.path
            guard resolved.hasPrefix("/"), !resolved.hasPrefix("/../") else { return nil }
            return String(resolved.dropFirst())
        }
    }
}
