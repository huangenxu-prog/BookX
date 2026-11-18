import Foundation
import Markdown
import SwiftSoup

/// Converts document structure into BookX's existing text pages and UTF-16 TOC.
enum StructuredTextReader {
    static func markdown(_ source: String) throws -> BookDocument {
        let tree = Markdown.Document(parsing: source)
        var document = BookDocument(text: "")
        func append(_ text: String, heading: Bool = false) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if !document.text.isEmpty { document.text += "\n\n" }
            if heading {
                document.chapters.append(BookChapter(title: text, offset: document.text.utf16.count))
            }
            document.text += text
        }
        func inlineText(_ node: Markup) -> String {
            if let html = node as? InlineHTML {
                return html.rawHTML.lowercased().hasPrefix("<br") ? "\n" : ""
            }
            if node.childCount > 0 { return node.children.map(inlineText).joined() }
            return (node as? InlineMarkup)?.plainText ?? ""
        }
        func visit(_ node: Markup) throws {
            try Task.checkCancellation()
            if let heading = node as? Heading {
                append(inlineText(heading), heading: true)
            } else if let paragraph = node as? Paragraph {
                append(inlineText(paragraph))
            } else if let code = node as? CodeBlock {
                append(code.code)
            } else if let html = node as? HTMLBlock {
                append(try self.html(html.rawHTML).text)
            } else if node is InlineContainer {
                append(inlineText(node))
            } else {
                for child in node.children { try visit(child) }
            }
        }
        try visit(tree)
        return document
    }

    static func html(_ source: String) throws -> BookDocument {
        let parsed = try SwiftSoup.parse(source)
        var document = BookDocument(title: try parsed.title(), text: "")
        let blocks: Set<String> = ["p", "div", "section", "article", "li", "ul", "ol",
                                   "blockquote", "pre", "tr", "h1", "h2", "h3", "h4", "h5", "h6"]
        let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
        func newline() {
            if !document.text.isEmpty && !document.text.hasSuffix("\n") { document.text += "\n" }
        }
        func visit(_ node: Node, preformatted: Bool = false) throws {
            try Task.checkCancellation()
            if let text = node as? TextNode {
                let raw = text.getWholeText()
                document.text += preformatted ? raw :
                    raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            if ["script", "style", "head", "noscript", "iframe", "object", "template"].contains(tag) { return }
            if blocks.contains(tag) { newline() }
            if headings.contains(tag) {
                let title = try element.text()
                if !title.isEmpty {
                    document.chapters.append(BookChapter(title: title, offset: document.text.utf16.count))
                }
            }
            if tag == "br" { document.text += "\n" }
            if tag == "img" { document.text += try element.attr("alt") }
            for child in element.getChildNodes() {
                try visit(child, preformatted: preformatted || tag == "pre")
            }
            if tag == "td" || tag == "th" { document.text += "\t" }
            if blocks.contains(tag) { newline() }
        }
        if let body = parsed.body() { try visit(body) }
        return document
    }
}
