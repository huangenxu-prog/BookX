import Foundation
import CoreGraphics

struct EPUBLocation: Codable, Sendable, Hashable {
    let resource: Int
    let offset: Int // UTF-16 position within the resource, independent of font or viewport.
}

struct EPUBChapterPages: Sendable {
    let resource: Int
    let length: Int
    let pages: [ReadingPage]
}

struct ReadingLayout: Sendable {
    let size: CGSize
    let font: Double
    let spacing: Double
    let paged: Bool
    func pages(_ text: String) throws -> [ReadingPage] {
        try Task.checkCancellation()
        let result = try paged ? ScreenPagination.pages(text, size: size, fontSize: font, lineSpacing: spacing)
            : BookPagination.pages(text, fontSize: font)
        try Task.checkCancellation()
        return result
    }
}

/// ZIPFoundation handles archive access. The existing XML parser handles XHTML.
/// Only the current resource and its immediate neighbors are prepared, never a full book.
enum EPUBReadingEngine {
    static func chapter(_ source: URL, index: EPUBResourceIndex, at resource: Int,
                        layout: ReadingLayout) async throws -> EPUBChapterPages {
        let text = try await EPUBResourceStore.chapter(source, index: index, at: resource)
        let pages = try layout.pages(text).map {
            ReadingPage(offset: $0.offset, text: $0.text, resourceIndex: resource)
        }
        return EPUBChapterPages(resource: resource, length: text.utf16.count, pages: pages)
    }
    static func readableChapter(_ source: URL, index: EPUBResourceIndex, startingAt resource: Int,
                                direction: Int, layout: ReadingLayout) async throws -> EPUBChapterPages? {
        var position = resource
        while index.resources.indices.contains(position) {
            try Task.checkCancellation()
            let result = try await chapter(source, index: index, at: position, layout: layout)
            if !result.pages.isEmpty { return result }
            position += direction < 0 ? -1 : 1
        }
        return nil
    }
    static func legacyLocation(_ source: URL, index: EPUBResourceIndex, offset: Int) async throws -> EPUBLocation {
        guard offset > 0 else { return EPUBLocation(resource: 0, offset: 0) }
        if let chapters = BookDocumentStore.cachedChapters(source), chapters.count == index.resources.count {
            let position = chapters.lastIndex(where: { $0.offset <= offset }) ?? 0
            return EPUBLocation(resource: position, offset: max(0, offset - chapters[position].offset))
        }
        // One-time compatibility path for historical bookmarks without cached metadata.
        // Extract only as far as the bookmark; new bookmarks never use whole-book offsets.
        var remaining = offset
        for position in index.resources.indices {
            try Task.checkCancellation()
            let text = try await EPUBResourceStore.chapter(source, index: index, at: position)
            guard !text.isEmpty else { continue }
            if remaining < text.utf16.count { return EPUBLocation(resource: position, offset: max(0, remaining)) }
            remaining -= text.utf16.count + 2
        }
        return EPUBLocation(resource: max(0, index.resources.count - 1), offset: Int.max)
    }
}

/// Cancel the detached work too, rather than merely discarding a late UI result.
func readerWorker<T: Sendable>(priority: TaskPriority = .userInitiated,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let result = try await task.value
        try Task.checkCancellation()
        return result
    } onCancel: { task.cancel() }
}

extension ReadingPage {
    var location: EPUBLocation { EPUBLocation(resource: resourceIndex ?? -1, offset: offset) }
}

/// Pure window update, shared by all presentation modes and regression tests.
enum EPUBWindow {
    static func adding(_ chapter: EPUBChapterPages, to existing: [Int: EPUBChapterPages],
                       anchor: EPUBLocation) -> (chapters: [Int: EPUBChapterPages], pages: [ReadingPage], selected: Int) {
        var chapters = existing
        chapters[chapter.resource] = chapter
        let retained = Set(chapters.keys.sorted {
            let a = abs($0 - anchor.resource), b = abs($1 - anchor.resource)
            return a == b ? $0 < $1 : a < b
        }.prefix(5))
        chapters = chapters.filter { retained.contains($0.key) }
        let pages = chapters.keys.sorted().flatMap { chapters[$0]!.pages }
        let selected = pages.firstIndex { $0.location == anchor } ?? 0
        return (chapters, pages, selected)
    }
}
