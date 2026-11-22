import Foundation
import CoreText
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Measurement and rendering share the same attributed text and Core Text frame.
enum ScreenPagination {
    static let horizontalInset: CGFloat = 24
    static let verticalInset: CGFloat = 20

    static func attributed(_ text: String, fontSize: Double, lineSpacing: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(lineSpacing)
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: CGFloat(fontSize))
        #else
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        #endif
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
    }

    static func frame(_ text: NSAttributedString, rect: CGRect) -> CTFrame {
        CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                                 CFRange(location: 0, length: 0),
                                 CGPath(rect: rect, transform: nil), nil)
    }

    static func pages(_ text: String, size: CGSize, fontSize: Double, lineSpacing: Double) throws -> [ReadingPage] {
        let rect = CGRect(x: 0, y: 0, width: floor(size.width) - horizontalInset * 2,
                          height: floor(size.height) - verticalInset * 2)
        guard rect.width > 0, rect.height > 0 else { return [] }
        let source = text as NSString
        var cursor = 0
        var characterOffset = 0
        var result: [ReadingPage] = []
        while cursor < source.length {
            try Task.checkCancellation()
            // A bounded window avoids laying out millions of characters for every page.
            let page: String = try autoreleasepool {
            let window = source.rangeOfComposedCharacterSequences(for:
                NSRange(location: cursor, length: min(4096, source.length - cursor)))
            let chunk = source.substring(with: window) as NSString
            let layout = frame(attributed(chunk as String, fontSize: fontSize, lineSpacing: lineSpacing), rect: rect)
            var count = CTFrameGetVisibleStringRange(layout).length
            if count > 0 && count < chunk.length {
                let last = chunk.rangeOfComposedCharacterSequence(at: count - 1)
                if NSMaxRange(last) > count { count = last.location }
            }
            guard count > 0 else { throw BookReadError.invalid("当前阅读区域太小，请缩小字号后重试。") }
            return chunk.substring(to: count)
            }
            result.append(ReadingPage(offset: characterOffset, text: page))
            characterOffset += page.utf16.count
            cursor += page.utf16.count
        }
        return result
    }
}

#if canImport(UIKit)
import SwiftUI


/// Loads only the currently displayed EPUB illustration; no full-book decoding.
struct EPUBIllustrationView: View {
    let bookURL: URL
    let path: String
    let alternative: String
    @State private var illustration: UIImage?

    var body: some View {
        Group {
            if let illustration {
                Image(uiImage: illustration)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(alternative.isEmpty ? "书籍插图" : alternative)
            } else {
                ProgressView()
                    .accessibilityLabel("正在加载插图")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .task(id: path) {
            illustration = nil
            guard let bytes = try? await BookDocumentLoader.epubImageData(bookURL, path: path),
                  !Task.isCancelled else { return }
            illustration = UIImage(data: bytes)
        }
    }
}

struct ScreenPageView: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let lineSpacing: Double
    let ink: Color
    /// Optional range of the sentence/word currently being narrated.
    var highlightRange: NSRange? = nil

    func makeUIView(context: Context) -> PageCanvas {
        let view = PageCanvas()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        return view
    }
    func updateUIView(_ view: PageCanvas, context: Context) {
        let value = NSMutableAttributedString(attributedString:
            ScreenPagination.attributed(text, fontSize: fontSize, lineSpacing: lineSpacing))
        value.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                           value: UIColor(ink).cgColor, range: NSRange(location: 0, length: value.length))
        view.content = value
        view.highlightRange = highlightRange
        view.accessibilityLabel = text
        view.setNeedsDisplay()
    }
    final class PageCanvas: UIView {
        var content = NSAttributedString(string: "")
        var highlightRange: NSRange?
        override func layoutSubviews() { super.layoutSubviews(); setNeedsDisplay() }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            let area = CGRect(x: ScreenPagination.horizontalInset, y: ScreenPagination.verticalInset,
                              width: floor(bounds.width) - ScreenPagination.horizontalInset * 2,
                              height: floor(bounds.height) - ScreenPagination.verticalInset * 2)
            guard area.width > 0, area.height > 0 else { context.restoreGState(); return }
            let frame = ScreenPagination.frame(content, rect: area)
            // Draw a translucent marker behind the exact Core Text glyphs.
            // Text layout and page breaks are unchanged.
            if let selected = highlightRange, selected.length > 0,
               selected.location >= 0, NSMaxRange(selected) <= content.length {
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating: .zero, count: lines.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
                for (i, line) in lines.enumerated() {
                    let lineRange = CTLineGetStringRange(line)
                    let beginning = max(selected.location, lineRange.location)
                    let ending = min(NSMaxRange(selected), lineRange.location + lineRange.length)
                    guard beginning < ending else { continue }
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    var leading: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                    let left = CGFloat(CTLineGetOffsetForStringIndex(line, beginning, nil))
                    let right = CGFloat(CTLineGetOffsetForStringIndex(line, ending, nil))
                    let origin = origins[i]
                    let marker = CGRect(x: origin.x + min(left, right) - 2,
                                        y: origin.y - descent - 2,
                                        width: abs(right - left) + 4,
                                        height: ascent + descent + 4)
                    context.addPath(CGPath(roundedRect: marker, cornerWidth: 3,
                                           cornerHeight: 3, transform: nil))
                    context.fillPath()
                }
            }
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
    }
}
#endif
