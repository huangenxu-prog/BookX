import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreFoundation

@main
struct BookXApp: App {
    @StateObject private var library = BookLibrary()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .onOpenURL { url in Task { await library.importFiles([url]) } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    library.clearDocumentCache()
                }
        }
    }
}


@MainActor
final class BookLibrary: ObservableObject {
    @Published var books: [BookItem] = []
    @Published var importError: String?
    @Published var importing = false
    @Published var fontSize: Double = 19
    @Published var lineSpacing: Double = 8
    @Published var paper: Int = 1
    @Published var pageMode: Int = 0
    private var progressSaveTask: Task<Void, Never>?
    // Keep only the most recently parsed book. Strings/arrays share value storage.
    private var documentCache: (id: UUID, document: BookDocument)?
    private var paginationCache: (id: UUID, key: String, pages: [ReadingPage])?
    func cachedPages(for id: UUID, key: String) -> [ReadingPage]? {
        guard paginationCache?.id == id, paginationCache?.key == key else { return nil }
        return paginationCache?.pages
    }
    func cachePages(_ pages: [ReadingPage], for id: UUID, key: String) {
        paginationCache = (id, key, pages)
    }
    func cachedDocument(for id: UUID) -> BookDocument? {
        documentCache?.id == id ? documentCache?.document : nil
    }
    func cacheDocument(_ document: BookDocument, for id: UUID) {
        if documentCache?.id != id { paginationCache = nil }
        documentCache = (id, document)
    }
    func clearDocumentCache() { documentCache = nil; paginationCache = nil }
    private let fm = FileManager.default
    private var folder: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    init() {
        load()
        #if DEBUG
        prepareUITest()
        #endif
    }
    #if DEBUG
    private func prepareUITest() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BOOKX_UI_TEST_RESET"] == "1" else { return }
        // Only a DEBUG UI-test launch may clear its own app sandbox.
        for book in books { try? fm.removeItem(at: fileURL(book)) }
        books = []
        fontSize = 19; lineSpacing = 8; paper = 1; pageMode = environment["BOOKX_UI_TEST_SCROLL"] == "1" ? 3 : 0
        save()
        let temporary = fm.temporaryDirectory.appendingPathComponent("BookX-UI", isDirectory: true)
        try? fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let textURL = temporary.appendingPathComponent("阅读测试.txt")
        let text = (1...160).map { "第\($0)段：清晨，阳光落在书页上。继续读下去，每一段文字都应该完整保留。\n" }.joined()
        try? text.write(to: textURL, atomically: true, encoding: .utf8)
        var urls = [textURL]
        if let encoded = environment["BOOKX_UI_TEST_EPUB"], let data = Data(base64Encoded: encoded) {
            let url = temporary.appendingPathComponent("sample.epub")
            try? data.write(to: url)
            urls.append(url)
        }
        Task { await importFiles(urls) }
    }
    #endif
    func load() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
           let items = try? JSONDecoder().decode([BookItem].self, from: data) { books = items }
        fontSize = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 19 : UserDefaults.standard.double(forKey: "fontSize")
        lineSpacing = UserDefaults.standard.object(forKey: "lineSpacing") == nil ? 8 : UserDefaults.standard.double(forKey: "lineSpacing")
        paper = UserDefaults.standard.object(forKey: "paper") == nil ? 1 : UserDefaults.standard.integer(forKey: "paper")
        pageMode = UserDefaults.standard.object(forKey: "pageMode") == nil ? 0 : UserDefaults.standard.integer(forKey: "pageMode")
        // Keep existing scrolling preferences; migrate the removed cover mode to horizontal paging.
        if pageMode == 2 { pageMode = 1 }
        if ![0, 1, 3].contains(pageMode) { pageMode = 0 }
    }
    func save() {
        progressSaveTask?.cancel()
        progressSaveTask = nil
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            importError = "无法保存书库或阅读进度：\(error.localizedDescription)"
        }
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        UserDefaults.standard.set(lineSpacing, forKey: "lineSpacing")
        UserDefaults.standard.set(paper, forKey: "paper")
        UserDefaults.standard.set(pageMode, forKey: "pageMode")
    }
    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for url in urls {
            if Task.isCancelled { break }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard ["txt", "epub", "md", "markdown", "rtf", "html", "htm", "fb2"].contains(url.pathExtension.lowercased()) else { continue }
            let name = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                let localURL = folder.appendingPathComponent(name)
                do {
                    let document = try await readerWorker {
                        if localURL.pathExtension.lowercased() == "epub" {
                            let index = try await EPUBResourceStore.index(localURL)
                            return BookDocument(title: index.title, author: index.author, text: "")
                        }
                        return try await BookDocumentStore.load(localURL)
                    }
                    let id = UUID()
                    if localURL.pathExtension.lowercased() != "epub" { cacheDocument(document, for: id) }
                    books.append(BookItem(id: id,
                        title: document.title.isEmpty ? url.deletingPathExtension().lastPathComponent : document.title,
                        author: document.author, filename: name, progress: 0, lastRead: nil))
                } catch {
                    try? fm.removeItem(at: localURL)
                    EPUBResourceStore.remove(localURL)
                    BookDocumentStore.remove(localURL)
                    throw error
                }
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        save()
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
    }
    func delete(_ book: BookItem) {
        do {
            let url = fileURL(book)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            BookDocumentStore.remove(url)
            BookPageStore.remove(url)
            EPUBResourceStore.remove(url)
            books.removeAll { $0.id == book.id }
            if documentCache?.id == book.id { clearDocumentCache() }
            save()
        } catch { importError = "删除失败：\(error.localizedDescription)" }
    }
    func removeFromShelf(_ book: BookItem) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].hiddenFromShelf = true
        save()
    }
    func fileURL(_ book: BookItem) -> URL { folder.appendingPathComponent(book.filename) }
    func updateProgress(_ id: UUID, _ value: Double, offset: Int, epubLocation: EPUBLocation? = nil) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].progress = min(1, max(0, value))
        books[index].readingOffset = offset
        books[index].epubLocation = epubLocation
        books[index].lastRead = Date()
        books[index].hiddenFromShelf = false
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}

private enum BookXStyle {
    static let purple = Color(red: 0.14, green: 0.32, blue: 0.26) // Forest green
    static let lilac = Color(red: 0.86, green: 0.91, blue: 0.85) // Soft sage
    static let ink = Color(red: 0.14, green: 0.19, blue: 0.16)
    static let muted = Color(red: 0.47, green: 0.53, blue: 0.49)
    static let paper = Color(red: 0.973, green: 0.977, blue: 0.960)
    static let panel = Color.white.opacity(0.84)
}

private struct BookCover: View {
    let title: String
    let large: Bool

    private var style: Int {
        let name = title.components(separatedBy: ["（", "(", "【", "["]).first ?? title
        if name.contains("明朝") { return 0 }
        if name.contains("万历") { return 1 }
        if name.contains("罪与罚") { return 2 }
        if name.contains("十日") { return 3 }
        if name.contains("牧神") { return 4 }
        if name.contains("道氏") { return 5 }
        return Int(name.unicodeScalars.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1.value)) &* UInt64(1099511628211)
        } % 6)
    }

    private var cloth: Color {
        [
            Color(red: 0.13, green: 0.32, blue: 0.26),
            Color(red: 0.88, green: 0.82, blue: 0.71),
            Color(red: 0.11, green: 0.23, blue: 0.33),
            Color(red: 0.37, green: 0.17, blue: 0.18),
            Color(red: 0.14, green: 0.25, blue: 0.33),
            Color(red: 0.84, green: 0.80, blue: 0.71)
        ][style]
    }
    private var artworkName: String {
        // Stable distribution across all twelve designs, independent of
        // book subject or reading order. The same title keeps its cover.
        let seed = shortTitle.unicodeScalars.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1.value)) &* UInt64(1099511628211)
        }
        return String(format: "BookCover%02d", Int(seed % 12) + 1)
    }
    private var lightCover: Bool { style == 1 || style == 5 }
    private var gold: Color { Color(red: 0.82, green: 0.68, blue: 0.44) }
    private var ink: Color {
        lightCover ? Color(red: 0.25, green: 0.21, blue: 0.17) :
            Color(red: 0.96, green: 0.86, blue: 0.67)
    }
    // Cover artwork and title color are one fixed visual theme.
    // Dark cloth uses warm ivory/gold; parchment uses dark brown.
    // Each artwork owns its typography. Never derive contrast from book title.
    private var coverNumber: Int { Int(artworkName.suffix(2)) ?? 1 }
    private var artworkTitleColor: Color {
        // All photographed covers have dark upper artwork or detailed foliage;
        // bright ivory with a dark outline is legible over both.
        switch coverNumber {
        case 4, 8, 12: return Color(red: 1.0, green: 0.97, blue: 0.86)
        default: return Color(red: 1.0, green: 0.93, blue: 0.75)
        }
    }
    private var artworkTitlePosition: CGFloat {
        switch coverNumber {
        case 4, 8, 12: return 0.24
        case 3, 7, 11: return 0.18
        default: return 0.13
        }
    }
    private var shortTitle: String {
        let cleaned = title.components(separatedBy: ["（", "(", "【", "["]).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? title
        return cleaned.replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [
                        cloth.opacity(0.85), cloth, cloth.opacity(0.94)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))

                // Deterministic fine cloth grain; no external assets or network.
                Canvas { context, size in
                    for i in 0..<180 {
                        let x = CGFloat((i * 47 + 13) % 191) / 191 * size.width
                        let y = CGFloat((i * 83 + 29) % 223) / 223 * size.height
                        let dot = CGRect(x: x, y: y, width: 0.55, height: 0.8)
                        context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.10)))
                    }
                }
                .allowsHitTesting(false)

                // The illustration is drawn in vectors and scales with the cover.
                BookCoverArtwork(variant: style, color: lightCover ?
                    Color(red: 0.40, green: 0.36, blue: 0.28) : gold)
                    .frame(width: w * 0.91, height: h * 0.46)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(lightCover ? 0.60 : 0.80)
                    .clipped()

                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(gold.opacity(lightCover ? 0.38 : 0.73), lineWidth: 0.75)
                    .padding(.leading, 12).padding(.trailing, 7).padding(.vertical, 8)

                HStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.19)).frame(width: 5)
                    Rectangle().fill(.white.opacity(0.14)).frame(width: 2)
                    Spacer(minLength: 0)
                }

                if UIImage(named: artworkName) != nil {
                    // Source illustrations contain a centered book surrounded
                    // by a wide parchment margin. Fill with the actual book,
                    // rather than showing a miniature book inside the cover.
                    Image(artworkName)
                        .resizable()
                        .scaledToFill()
                        // The source includes an outer decorative margin.
                        // Crop that margin inside the fixed cover bounds.
                        // Slight overscan removes the photographed paper edges,
                        // while keeping the book illustration centered.
                        .frame(width: w, height: h)
                        .clipped()
                }

                VStack(spacing: 7) {
                    Spacer().frame(height: h * artworkTitlePosition)
                    Text(shortTitle)
                        .font(.system(size: large ? 19 : 11, weight: .semibold, design: .serif))
                         .foregroundStyle(UIImage(named: artworkName) == nil ? ink : artworkTitleColor)
                        .shadow(color: .black.opacity(0.95), radius: 1.7, x: 0, y: 1)
                        .multilineTextAlignment(.center)
                        .lineLimit(large ? 4 : 3)
                        .minimumScaleFactor(0.68)
                        .frame(maxWidth: w * 0.78)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .aspectRatio(0.69, contentMode: .fit)
        .shadow(color: .black.opacity(0.17), radius: 9, x: 2, y: 8)
        .accessibilityLabel("封面：\(title)")
    }
}

// Small, scalable ink-and-gold book illustrations, not SF Symbol placeholders.
private struct BookCoverArtwork: View {
    let variant: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var lines = Path()
            switch variant {
            case 0, 1, 4, 5:
                // Layered landscape, reminiscent of traditional engraved endpapers.
                for layer in 0..<3 {
                    let shift = CGFloat(layer) * 0.12
                    lines.move(to: CGPoint(x: 0, y: h * (0.75 + shift)))
                    lines.addLine(to: CGPoint(x: w * 0.20, y: h * (0.44 + shift)))
                    lines.addLine(to: CGPoint(x: w * 0.37, y: h * (0.65 + shift)))
                    lines.addLine(to: CGPoint(x: w * 0.61, y: h * (0.30 + shift)))
                    lines.addLine(to: CGPoint(x: w * 0.83, y: h * (0.62 + shift)))
                    lines.addLine(to: CGPoint(x: w, y: h * (0.48 + shift)))
                }
                if variant == 0 || variant == 1 {
                    // A compact palace roof / old city silhouette.
                    let roof = h * 0.80
                    lines.move(to: CGPoint(x: w * 0.22, y: roof))
                    lines.addQuadCurve(to: CGPoint(x: w * 0.78, y: roof),
                                       control: CGPoint(x: w * 0.50, y: h * 0.56))
                    lines.move(to: CGPoint(x: w * 0.28, y: roof + 3))
                    lines.addLine(to: CGPoint(x: w * 0.72, y: roof + 3))
                    for i in 0..<5 {
                        let x = w * (0.30 + CGFloat(i) * 0.10)
                        lines.move(to: CGPoint(x: x, y: roof + 3))
                        lines.addLine(to: CGPoint(x: x, y: h * 0.96))
                    }
                }
            case 2:
                // Engraved bamboo leaves.
                lines.move(to: CGPoint(x: w * 0.22, y: h))
                lines.addQuadCurve(to: CGPoint(x: w * 0.75, y: h * 0.10),
                                   control: CGPoint(x: w * 0.40, y: h * 0.52))
                for i in 0..<6 {
                    let y = h * (0.20 + CGFloat(i) * 0.11)
                    let x = w * (0.69 - CGFloat(i) * 0.055)
                    lines.move(to: CGPoint(x: x, y: y))
                    lines.addQuadCurve(to: CGPoint(x: x - w * 0.27, y: y - h * 0.12),
                                       control: CGPoint(x: x - w * 0.20, y: y - h * 0.14))
                    lines.move(to: CGPoint(x: x, y: y))
                    lines.addQuadCurve(to: CGPoint(x: x + w * 0.23, y: y - h * 0.13),
                                       control: CGPoint(x: x + w * 0.18, y: y - h * 0.14))
                }
            default:
                // A flowering branch, with small hand-drawn five-petal blossoms.
                lines.move(to: CGPoint(x: w * 0.20, y: h))
                lines.addQuadCurve(to: CGPoint(x: w * 0.76, y: h * 0.20),
                                   control: CGPoint(x: w * 0.43, y: h * 0.48))
                for i in 0..<5 {
                    let x = w * (0.32 + CGFloat(i) * 0.10)
                    let y = h * (0.83 - CGFloat(i) * 0.13)
                    for petal in 0..<5 {
                        let angle = CGFloat(petal) * (.pi * 2 / 5)
                        let px = x + cos(angle) * w * 0.035
                        let py = y + sin(angle) * w * 0.035
                        lines.addEllipse(in: CGRect(x: px - 2.5, y: py - 2.5,
                                                    width: 5, height: 5))
                    }
                }
            }
            context.stroke(lines, with: .color(color), lineWidth: max(0.7, w / 135))
        }
        .accessibilityHidden(true)
    }
}

private struct BookSpine: View {
    let title: String
    let seed: Int
    let styleIndex: Int
    let width: CGFloat

    private var assetName: String {
        String(format: "BookSpine%02d", styleIndex % 10 + 1)
    }
    private var lightSpine: Bool { [0, 2, 6].contains(styleIndex % 10) }
    private var ink: Color {
        lightSpine ? Color(red: 0.24, green: 0.19, blue: 0.13) :
            Color(red: 0.96, green: 0.83, blue: 0.57)
    }
    private var spineTitle: String {
        let cleaned = title.replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
        return cleaned.components(separatedBy: ["（", "(", "【", "["]).first ?? cleaned
    }
    private var titleSize: CGFloat {
        switch spineTitle.count {
        case 0...5: return 19
        case 6...8: return 16
        default: return 14
        }
    }

    var body: some View {
        ZStack {
            // The artwork contains the entire leather spine, embossed trim,
            // edge highlights and illustration. Only the book title is drawn in code.
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: 230)
                .clipped()
            VStack(spacing: 0) {
                ForEach(Array(spineTitle.prefix(11).enumerated()), id: \.offset) { entry in
                    Text(String(entry.element))
                        .font(.system(size: titleSize, weight: .semibold, design: .serif))
                        .fixedSize()
                }
            }
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(lightSpine ? 0.08 : 0.40), radius: 0.8, y: 1)
            .frame(width: width - 8)
            .offset(y: -23)
        }
        .frame(width: width, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.19), radius: 3, x: 2, y: 3)
        .accessibilityHidden(true)
    }
}

private struct SpineOrnament: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        switch variant {
        case 0:
            // Layered ink-wash mountains, like the pale spines in the reference.
            for layer in 0..<3 {
                let baseline = h * (0.68 + CGFloat(layer) * 0.10)
                p.move(to: CGPoint(x: 0, y: baseline))
                p.addLine(to: CGPoint(x: w * 0.24, y: baseline - h * (0.30 - CGFloat(layer) * 0.055)))
                p.addLine(to: CGPoint(x: w * 0.43, y: baseline - h * 0.10))
                p.addLine(to: CGPoint(x: w * 0.63, y: baseline - h * (0.39 - CGFloat(layer) * 0.06)))
                p.addLine(to: CGPoint(x: w, y: baseline))
            }
        case 1:
            // Engraved waves with nested curves.
            for row in 0..<5 {
                let y = h * (0.45 + CGFloat(row) * 0.095)
                p.move(to: CGPoint(x: 0, y: y))
                p.addQuadCurve(to: CGPoint(x: w * 0.52, y: y),
                               control: CGPoint(x: w * 0.26, y: y - h * 0.38))
                p.addQuadCurve(to: CGPoint(x: w, y: y),
                               control: CGPoint(x: w * 0.78, y: y - h * 0.30))
            }
        default:
            // Old-city roofline and a lantern silhouette.
            let y = h * 0.63
            p.move(to: CGPoint(x: w * 0.08, y: y))
            p.addQuadCurve(to: CGPoint(x: w * 0.92, y: y),
                           control: CGPoint(x: w * 0.5, y: h * 0.12))
            p.move(to: CGPoint(x: w * 0.17, y: y + 3))
            p.addLine(to: CGPoint(x: w * 0.83, y: y + 3))
            for i in 0..<4 {
                let x = w * (0.23 + CGFloat(i) * 0.18)
                p.move(to: CGPoint(x: x, y: y + 3))
                p.addLine(to: CGPoint(x: x, y: h * 0.93))
            }
            p.move(to: CGPoint(x: w * 0.10, y: h * 0.94))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.94))
        }
        return p
    }
}

private struct BookOpeningOverlay: View {
    let title: String
    let stage: Int
    var showBackdrop: Bool = true
    var fromLibrary: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(showBackdrop ? 0.10 : 0)
                .ignoresSafeArea()
            // One continuous cover movement: no artificial white inner page,
            // no reverse-opening hinge, and no second page-turn animation.
            BookCover(title: title, large: true)
                .frame(width: 228, height: 334)
                .scaleEffect(fromLibrary
                    ? (stage == 0 ? 0.84 : (stage == 1 ? 0.98 : 1.13))
                    : (stage == 0 ? 0.76 : (stage == 1 ? 0.96 : 1.13)))
                // Library spines face sideways; rotate the cover into view.
                // Shelf covers are already front-facing and remain unchanged.
                .rotation3DEffect(
                    .degrees(fromLibrary ? (stage == 0 ? 82 : (stage == 1 ? 38 : 0)) : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.42
                )
                .rotationEffect(.degrees(!fromLibrary && stage == 0 ? -4 : 0))
                .shadow(color: .black.opacity(0.20), radius: 17, y: 11)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在打开《" + title + "》")
    }
}

private struct ReaderOpeningTransition: View {
    let book: BookItem
    let onClose: () -> Void
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealReader = false
    @State private var readerReady = false
    @State private var openingMotionFinished = false

    private func revealIfReady() {
        guard readerReady, openingMotionFinished else { return }
        withAnimation(.easeOut(duration: 0.42)) { revealReader = true }
    }

    var body: some View {
        ZStack {
            ReaderView(book: book, onClose: onClose, onInitialReady: {
                readerReady = true
                revealIfReady()
            })
                .environmentObject(library)
                .opacity(revealReader || reduceMotion ? 1 : 0)

            if !reduceMotion {
                // A single, short cover-to-reader dissolve. Do not introduce
                // a second 3D page turn after the initial shelf animation.
                BookCover(title: book.title, large: true)
                    .frame(width: 228, height: 334)
                    .scaleEffect(revealReader ? 1.12 : 1)
                    .opacity(revealReader ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(red: 0.96, green: 0.92, blue: 0.83).ignoresSafeArea())
        .onAppear {
            // ReaderView starts loading immediately behind the cover.
            // Keep the cover visible until its first pages are ready.
            if reduceMotion { openingMotionFinished = true; revealIfReady(); return }
            Task { @MainActor in
                // Allow the physical cover to settle while ReaderView prepares pages.
                try? await Task.sleep(for: .milliseconds(560))
                openingMotionFinished = true
                revealIfReady()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: BookLibrary
    @State private var tab = 0
    @Namespace private var glassSelection
    @State private var importer = false
    @State private var settings = false
    @State private var selected: BookItem?
    @State private var pendingDeletion: BookItem?
    @State private var pendingShelfRemoval: BookItem?
    private var recent: [BookItem] {
        library.books.filter { $0.lastRead != nil && $0.hiddenFromShelf != true }
            .sorted { ($0.lastRead ?? .distantPast) > ($1.lastRead ?? .distantPast) }
    }
    private var sortedBooks: [BookItem] {
        library.books.sorted {
            $0.title.compare($1.title, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN")) == .orderedAscending
        }
    }
    private func initial(_ title: String) -> String {
        guard let first = title.first else { return "#" }
        let latin = (String(first).applyingTransform(.toLatin, reverse: false) ?? String(first))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "zh_CN"))
        let letter = latin.prefix(1).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
    }
    var body: some View {
        presentedReader
    }

    private var rootLayout: some View {
        ZStack {
            BookXStyle.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if tab == 0 { shelfContent } else { libraryContent }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                bottomBar
            }
            if let animatedBook {
                BookOpeningOverlay(title: animatedBook.title, stage: bookOpeningStage,
                                   fromLibrary: tab == 1)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    private var libraryDialogs: some View {
        rootLayout
            .preferredColorScheme(.light)
            .onChange(of: library.books.count) { old, new in if new > old { tab = 1 } }
            .confirmationDialog("删除这本书及阅读记录？", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                if let book = pendingDeletion {
                    Button("删除《\(book.title)》", role: .destructive) { library.delete(book); pendingDeletion = nil }
                }
            }
            .confirmationDialog("移出书架？", isPresented: Binding(
                get: { pendingShelfRemoval != nil },
                set: { if !$0 { pendingShelfRemoval = nil } }
            ), titleVisibility: .visible) {
                if let book = pendingShelfRemoval {
                    Button("移出书架") { library.removeFromShelf(book); pendingShelfRemoval = nil }
                }
            } message: {
                Text("书籍仍保留在书库，阅读进度不会丢失。")
            }
    }

    private var importingView: some View {
        libraryDialogs
            .tint(BookXStyle.purple)
            .fileImporter(isPresented: $importer, allowedContentTypes: importTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.importError = error.localizedDescription
                }
            }
            .overlay {
                if library.importing {
                    ProgressView("正在导入书籍")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
    }

    private var importTypes: [UTType] {
        [.plainText, UTType(filenameExtension: "epub") ?? .data,
         UTType(filenameExtension: "md") ?? .plainText,
         UTType(filenameExtension: "markdown") ?? .plainText,
         .rtf, .html, UTType(filenameExtension: "fb2") ?? .xml]
    }

    private var presentedReader: some View {
        importingView
            .alert("提示", isPresented: Binding(
                get: { library.importError != nil },
                set: { if !$0 { library.importError = nil } }
            )) {
                Button("知道了", role: .cancel) { library.importError = nil }
            } message: {
                Text(library.importError ?? "")
            }
            .sheet(isPresented: $settings) {
                SettingsView().environmentObject(library).presentationDetents([.medium, .large])
            }
            // Present in the same view hierarchy. A fullScreenCover always
            // slides upward on iOS, breaking the physical book-opening motion.
            .overlay {
                if let book = selected {
                    ReaderOpeningTransition(book: book, onClose: { selected = nil })
                        .environmentObject(library)
                        .zIndex(20)
                }
            }

    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                Text(tab == 0 ? "书架" : "书库")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(BookXStyle.ink)
                Text("阅")
                    .font(.system(size: 11, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .frame(width: 23, height: 23)
                    .background(BookXStyle.purple, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
                if tab == 0 {
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(BookXStyle.ink)
                            .frame(width: 46, height: 46)
                            .background(BookXStyle.panel, in: Circle())
                    }.accessibilityLabel("阅读设置")
                }
            }
            Text(tab == 0 ? "读过 \(recent.count) 本" : "共 \(library.books.count) 本")
                .font(.system(size: 14))
                .foregroundStyle(BookXStyle.muted)
        }.padding(.bottom, 9)
    }
    @ViewBuilder private var shelfContent: some View {
        if let first = recent.first {
            Button { selected = first } label: {
                HStack(alignment: .center, spacing: 17) {
                    BookCover(title: first.title, large: true).frame(width: 116)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("继续阅读").font(.subheadline.weight(.medium)).foregroundStyle(BookXStyle.purple)
                        Text(first.title).font(.system(size: 23, weight: .bold)).foregroundStyle(BookXStyle.ink).lineLimit(2)
                        if !first.author.isEmpty {
                            Text(first.author).font(.subheadline).foregroundStyle(BookXStyle.muted)
                        }
                        Text("已读 \(Int(first.progress * 100))%")
                            .font(.subheadline).foregroundStyle(BookXStyle.muted)
                        progressBar(first.progress)
                        Text("继续")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(BookXStyle.purple, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BookXStyle.panel, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: BookXStyle.purple.opacity(0.09), radius: 16, y: 7)
            }.buttonStyle(.plain).accessibilityIdentifier("continue-reading")
            .contextMenu {
                Button("移出书架", systemImage: "books.vertical") { pendingShelfRemoval = first }
            }
            if recent.count > 1 {
                sectionTitle("更早读过").padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 20) {
                    ForEach(recent.dropFirst()) { book in
                        Button { selected = book } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                BookCover(title: book.title, large: true)
                                Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("已读 \(Int(book.progress * 100))%")
                                    .font(.caption).foregroundStyle(BookXStyle.muted)
                                progressBar(book.progress)
                            }.foregroundStyle(BookXStyle.ink)
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("移出书架", systemImage: "books.vertical") { pendingShelfRemoval = book }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("还没有阅读记录", systemImage: "books.vertical", description: Text("从书库打开一本书，即可在这里继续阅读"))
                .padding(.top, 45)
        }
    }
    @State private var pullingBook: UUID?
    @State private var animatedBook: BookItem?
    @State private var bookOpeningStage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func takeBook(_ book: BookItem) {
        guard pullingBook == nil, animatedBook == nil else { return }
        if reduceMotion {
            selected = book
            return
        }
        pullingBook = book.id
        animatedBook = book
        bookOpeningStage = 0
        Task { @MainActor in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { bookOpeningStage = 1 }
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.easeOut(duration: 0.20)) { bookOpeningStage = 2 }
            try? await Task.sleep(for: .milliseconds(210))
            library.updateProgress(book.id, book.progress, offset: book.readingOffset ?? 0, epubLocation: book.epubLocation)
            selected = book
            animatedBook = nil
            pullingBook = nil
            bookOpeningStage = 0
        }
    }

    @ViewBuilder private var libraryContent: some View {
        if library.books.isEmpty {
            ContentUnavailableView("书库为空", systemImage: "book.closed", description: Text("点击下方 + 导入电子书"))
                .padding(.top, 45)
        } else {
            // Dense real-bookshelf layout: nine original-proportion spines per row.
            // Keep each spine at its original minimum 33pt width; never compress
            // artwork to fill the shelf. At 9 x 33 + 8 x 2 = 313pt, the row
            // fits the usable width of iPhone 16 without horizontal scrolling.
            GeometryReader { geometry in
                let availableWidth = max(0, geometry.size.width)
                let spineWidth: CGFloat = 33
                let gap: CGFloat = 2
                VStack(spacing: 24) {
                    ForEach(Array(stride(from: 0, to: sortedBooks.count, by: 9)), id: \.self) { start in
                        VStack(spacing: 0) {
                            HStack(alignment: .bottom, spacing: gap) {
                                ForEach(Array(sortedBooks[start..<min(start + 9, sortedBooks.count)].enumerated()), id: \.element.id) { offset, book in
                                    Button { takeBook(book) } label: {
                                        BookSpine(title: book.title,
                                                  seed: book.title.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) },
                                                  styleIndex: Int((book.title.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* UInt64(1099511628211) }) % 10),
                                                  width: spineWidth)
                                            .frame(width: spineWidth, height: 230)
                                            .clipped()
                                            .offset(y: pullingBook == book.id ? -22 : 0)
                                            .scaleEffect(pullingBook == book.id ? 1.07 : 1)
                                    }
                                    .frame(width: spineWidth, height: 230)
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(book.title)
                                    .accessibilityIdentifier("library-book-" + book.title)
                                    .contextMenu {
                                        Button("删除书籍", role: .destructive) { pendingDeletion = book }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [
                                    Color(red: 0.78, green: 0.53, blue: 0.32),
                                    Color(red: 0.55, green: 0.33, blue: 0.18)
                                ], startPoint: .top, endPoint: .bottom))
                                .frame(height: 10)
                                .overlay {
                                    if UIImage(named: "BookShelfWood") != nil {
                                        Image("BookShelfWood").resizable().scaledToFill()
                                            .frame(height: 10).clipped()
                                    }
                                }
                                .overlay(alignment: .top) {
                                    Rectangle().fill(.white.opacity(0.38)).frame(height: 1)
                                }
                                .shadow(color: .black.opacity(0.20), radius: 4, y: 4)
                        }
                    }
                }
                .frame(width: availableWidth, alignment: .center)
            }
            .frame(height: CGFloat((sortedBooks.count + 8) / 9) * 240 + CGFloat(max(0, (sortedBooks.count + 8) / 9 - 1)) * 24)
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 9) {
            Capsule().fill(BookXStyle.purple).frame(width: 4, height: 21)
            Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(BookXStyle.ink)
        }
    }
    private func progressBar(_ value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BookXStyle.lilac)
                Capsule().fill(BookXStyle.purple).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }.frame(height: 5)
    }
    private var bottomBar: some View {
        HStack(spacing: 9) {
            tabButton("books.vertical", "书架", index: 0)
            Button { importer = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 68)
                    .background(BookXStyle.ink, in: Capsule())
            }
            .accessibilityLabel("导入书籍")
            .disabled(library.importing)
            tabButton("line.3.horizontal", "书库", index: 1)
        }
        .padding(7)
        .background { glassBarBackground }
        .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 1))
        .shadow(color: BookXStyle.purple.opacity(0.12), radius: 16, y: 7)
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }
    @ViewBuilder private var glassBarBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.ultraThinMaterial)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }
    private func tabButton(_ symbol: String, _ title: String, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { tab = index }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 24))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tab == index ? BookXStyle.purple : BookXStyle.ink)
            .frame(maxWidth: .infinity).frame(height: 68)
            .background {
                if tab == index {
                    Capsule()
                        .fill(BookXStyle.lilac.opacity(0.64))
                        .matchedGeometryEffect(id: "selected-glass-tab", in: glassSelection)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(index == 0 ? "tab-shelf" : "tab-library")
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibrary
    private let accent = Color(red: 0.14, green: 0.32, blue: 0.26)
    private let paper = Color(red: 0.973, green: 0.977, blue: 0.960)
    private let ink = Color(red: 0.14, green: 0.19, blue: 0.16)
    private let backgrounds: [(String, Color)] = [
        ("白色", .white),
        ("米黄", Color(red: 0.97, green: 0.93, blue: 0.85)),
        ("护眼绿", Color(red: 0.86, green: 0.92, blue: 0.85)),
        ("深色", Color(red: 0.13, green: 0.13, blue: 0.13))
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("字号").font(.headline)
                            Spacer()
                            Text("\(Int(library.fontSize))").monospacedDigit().foregroundStyle(accent)
                        }
                        Slider(value: $library.fontSize, in: 14...30, step: 1).tint(accent)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("行距").font(.headline)
                            Spacer()
                            Text(String(format: "%.1f", library.lineSpacing / 10 + 1))
                                .monospacedDigit().foregroundStyle(accent)
                        }
                        Slider(value: $library.lineSpacing, in: 2...20, step: 1).tint(accent)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("背景").font(.headline)
                        HStack(spacing: 16) {
                            ForEach(backgrounds.indices, id: \.self) { index in
                                Button { library.paper = index } label: {
                                    VStack(spacing: 7) {
                                        Circle()
                                            .fill(backgrounds[index].1)
                                            .frame(width: 49, height: 49)
                                            .overlay(Circle().stroke(library.paper == index ? accent : ink.opacity(0.12), lineWidth: library.paper == index ? 2.5 : 1))
                                            .overlay {
                                                if library.paper == index {
                                                    Image(systemName: "checkmark").font(.caption.bold())
                                                        .foregroundStyle(index == 3 ? .white : accent)
                                                }
                                            }
                                        Text(backgrounds[index].0).font(.caption).foregroundStyle(ink)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("翻页").font(.headline)
                        Picker("翻页", selection: $library.pageMode) {
                            Text("仿真翻页").tag(0)
                            Text("左右滑动").tag(1)
                            Text("上下滚动").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("page-mode-picker")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("阅读预览").font(.caption).foregroundStyle(.secondary)
                        Text("知是行之始，行是知之成。")
                            .font(.system(size: library.fontSize, design: .serif))
                            .lineSpacing(library.lineSpacing)
                            .foregroundStyle(library.paper == 3 ? Color.white : ink)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                            .background(backgrounds[library.paper].1, in: RoundedRectangle(cornerRadius: 16))
                        Text("可在阅读时切换翻页方式").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .background(paper.ignoresSafeArea())
            .foregroundStyle(ink)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { library.save(); dismiss() }.tint(accent)
            } }
            .onDisappear { library.save() }
        }
    }
}
