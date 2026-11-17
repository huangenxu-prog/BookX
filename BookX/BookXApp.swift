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
        fontSize = 19; lineSpacing = 8; paper = 1; pageMode = 0
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
            guard ["txt", "epub"].contains(url.pathExtension.lowercased()) else { continue }
            let name = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                let localURL = folder.appendingPathComponent(name)
                do {
                    let document = try await readerWorker {
                        if localURL.pathExtension.lowercased() == "epub" {
                            let index = try EPUBResourceStore.index(localURL)
                            return BookDocument(title: index.title, author: index.author, text: "")
                        }
                        return try BookDocumentStore.load(localURL)
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
    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.31, green: 0.47, blue: 0.41), Color(red: 0.09, green: 0.24, blue: 0.20)],
            [Color(red: 0.83, green: 0.83, blue: 0.81), Color(red: 0.16, green: 0.17, blue: 0.17)],
            [Color(red: 0.88, green: 0.86, blue: 0.79), Color(red: 0.18, green: 0.18, blue: 0.17)],
            [Color(red: 0.75, green: 0.67, blue: 0.53), Color(red: 0.20, green: 0.17, blue: 0.14)]
        ]
        let index = title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palettes.count
        return palettes[index]
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 3)
                .stroke(.white.opacity(0.28), lineWidth: 1)
                .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 7)
            HStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.18)).frame(width: 6)
                Rectangle().fill(.white.opacity(0.13)).frame(width: 2)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top) {
                Text("读")
                    .font(.system(size: large ? 10 : 7, weight: .bold))
                    .foregroundStyle(BookXStyle.purple)
                    .padding(4)
                    .background(BookXStyle.paper.opacity(0.95), in: RoundedRectangle(cornerRadius: 2))
                Spacer()
                Text(title)
                    .font(.system(size: large ? 21 : 13, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(5)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: large ? 42 : 30)
            }
            .padding(.horizontal, large ? 15 : 10)
            .padding(.top, large ? 19 : 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .aspectRatio(0.69, contentMode: .fit)
        .shadow(color: .black.opacity(0.17), radius: 9, x: 2, y: 8)
        .accessibilityLabel("封面：\(title)")
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
        }
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
        .tint(BookXStyle.purple)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await library.importFiles(urls) }
            case .failure(let error): library.importError = error.localizedDescription
            }
        }
        .overlay {
            if library.importing {
                ProgressView("正在导入书籍")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert("提示", isPresented: Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })) {
            Button("知道了", role: .cancel) { library.importError = nil }
        } message: { Text(library.importError ?? "") }
        .sheet(isPresented: $settings) {
            SettingsView().environmentObject(library).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $selected) { book in
            ReaderView(book: book).environmentObject(library)
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
    @ViewBuilder private var libraryContent: some View {
        if library.books.isEmpty {
            ContentUnavailableView("书库为空", systemImage: "book.closed", description: Text("点击下方 + 导入 TXT 或 EPUB"))
                .padding(.top, 45)
        } else {
            let letters = Array(Set(sortedBooks.map { initial($0.title) })).sorted()
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BookXStyle.purple)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .background(BookXStyle.lilac.opacity(0.55), in: Capsule())
                ForEach(sortedBooks.filter { initial($0.title) == letter }) { book in
                    Button { selected = book } label: {
                        HStack(spacing: 16) {
                            BookCover(title: book.title, large: false).frame(width: 65)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(book.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(BookXStyle.ink)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !book.author.isEmpty {
                                    Text(book.author).font(.subheadline).foregroundStyle(BookXStyle.muted).lineLimit(1).truncationMode(.tail)
                                }
                            }
                            Image(systemName: "chevron.right").foregroundStyle(BookXStyle.purple)
                                .frame(width: 20)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BookXStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(color: BookXStyle.purple.opacity(0.08), radius: 12, y: 5)
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("library-book-" + book.title)
                    .contextMenu {
                        Button("删除书籍", role: .destructive) { pendingDeletion = book }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDeletion = book } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
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
