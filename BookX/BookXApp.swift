import SwiftUI
import UniformTypeIdentifiers
import CoreFoundation

@main
struct BookXApp: App {
    @StateObject private var library = BookLibrary()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}

struct BookItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var author: String
    var filename: String
    var progress: Double
    var lastRead: Date?
    var readingOffset: Int?
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
    private let fm = FileManager.default
    private var folder: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    init() { load() }
    func load() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
           let items = try? JSONDecoder().decode([BookItem].self, from: data) { books = items }
        fontSize = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 19 : UserDefaults.standard.double(forKey: "fontSize")
        lineSpacing = UserDefaults.standard.object(forKey: "lineSpacing") == nil ? 8 : UserDefaults.standard.double(forKey: "lineSpacing")
        paper = UserDefaults.standard.object(forKey: "paper") == nil ? 1 : UserDefaults.standard.integer(forKey: "paper")
        pageMode = UserDefaults.standard.integer(forKey: "pageMode")
    }
    func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
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
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard ["txt", "epub"].contains(url.pathExtension.lowercased()) else { continue }
            let name = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                let localURL = folder.appendingPathComponent(name)
                do {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try BookDocumentLoader.load(localURL)
                    }.value
                    books.append(BookItem(id: UUID(),
                        title: document.title.isEmpty ? url.deletingPathExtension().lastPathComponent : document.title,
                        author: document.author, filename: name, progress: 0, lastRead: nil))
                } catch {
                    try? fm.removeItem(at: localURL)
                    throw error
                }
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        save()
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
    }
    func fileURL(_ book: BookItem) -> URL { folder.appendingPathComponent(book.filename) }
    func updateProgress(_ id: UUID, _ value: Double, offset: Int) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].progress = min(1, max(0, value))
        books[index].readingOffset = offset
        books[index].lastRead = Date()
        save()
    }
}

private enum BookXStyle {
    static let purple = Color(red: 0.43, green: 0.16, blue: 0.60)
    static let lilac = Color(red: 0.91, green: 0.83, blue: 0.98)
    static let ink = Color(red: 0.16, green: 0.11, blue: 0.23)
    static let muted = Color(red: 0.48, green: 0.43, blue: 0.55)
}

private struct BookCover: View {
    let title: String
    let large: Bool
    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.79, green: 0.88, blue: 0.81), Color(red: 0.91, green: 0.96, blue: 0.90)],
            [Color(red: 0.95, green: 0.83, blue: 0.68), Color(red: 0.99, green: 0.94, blue: 0.85)],
            [Color(red: 0.79, green: 0.85, blue: 0.95), Color(red: 0.93, green: 0.95, blue: 0.99)],
            [Color(red: 0.91, green: 0.86, blue: 0.72), Color(red: 0.98, green: 0.95, blue: 0.85)]
        ]
        let index = title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palettes.count
        return palettes[index]
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 7)
                .stroke(BookXStyle.ink.opacity(0.18), lineWidth: 1)
                .padding(9)
            Text(title)
                .font(.system(size: large ? 23 : 15, weight: .semibold, design: .serif))
                .foregroundStyle(BookXStyle.ink)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .padding(15)
        }
        .aspectRatio(0.69, contentMode: .fit)
        .shadow(color: BookXStyle.purple.opacity(0.10), radius: 8, y: 5)
        .accessibilityLabel("封面：\(title)")
    }
}

struct RootView: View {
    @EnvironmentObject private var library: BookLibrary
    @State private var tab = 0
    @State private var importer = false
    @State private var settings = false
    @State private var selected: BookItem?
    private var recent: [BookItem] {
        library.books.filter { $0.lastRead != nil }
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
            LinearGradient(colors: [
                Color(red: 0.92, green: 0.82, blue: 0.97),
                Color(red: 0.97, green: 0.94, blue: 1.0),
                Color(red: 0.99, green: 0.97, blue: 1.0)
            ], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
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
        .alert("导入未完成", isPresented: Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })) {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "book.closed.fill").font(.title2)
                Text("BookX").font(.system(size: 24, weight: .bold, design: .serif))
                Spacer()
                if tab == 0 {
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3.weight(.medium))
                            .frame(width: 50, height: 50)
                            .background(.white.opacity(0.75), in: Circle())
                            .shadow(color: BookXStyle.purple.opacity(0.1), radius: 9, y: 4)
                    }
                    .accessibilityLabel("阅读设置")
                }
            }
            .foregroundStyle(BookXStyle.purple)
            Text(tab == 0 ? "书架" : "书库")
                .font(.system(size: 43, weight: .bold, design: .serif))
                .foregroundStyle(BookXStyle.ink)
            Text(tab == 0 ? "读过 \(recent.count) 本" : "共 \(library.books.count) 本")
                .font(.system(size: 16))
                .foregroundStyle(BookXStyle.muted)
        }
        .padding(.bottom, 6)
    }
    @ViewBuilder private var shelfContent: some View {
        if let first = recent.first {
            sectionTitle("最近阅读")
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
                        Text("继续阅读  ›")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BookXStyle.purple)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(BookXStyle.lilac.opacity(0.8), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 26))
                .shadow(color: BookXStyle.purple.opacity(0.09), radius: 16, y: 7)
            }.buttonStyle(.plain)
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
                    .background(BookXStyle.lilac.opacity(0.65), in: Capsule())
                ForEach(sortedBooks.filter { initial($0.title) == letter }) { book in
                    Button { selected = book } label: {
                        HStack(spacing: 16) {
                            BookCover(title: book.title, large: false).frame(width: 65)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(book.title).font(.system(size: 20, weight: .bold)).foregroundStyle(BookXStyle.ink)
                                if !book.author.isEmpty {
                                    Text(book.author).font(.subheadline).foregroundStyle(BookXStyle.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(BookXStyle.purple)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 22))
                        .shadow(color: BookXStyle.purple.opacity(0.08), radius: 12, y: 5)
                    }.buttonStyle(.plain)
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
            tabButton("books.vertical.fill", "书架", index: 0)
            Button { importer = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 68)
                    .background(BookXStyle.purple.gradient, in: Capsule())
            }.accessibilityLabel("导入书籍").disabled(library.importing)
            tabButton("book.open", "书库", index: 1)
        }
        .padding(7)
        .background(.white.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(BookXStyle.purple.opacity(0.13), lineWidth: 1))
        .shadow(color: BookXStyle.purple.opacity(0.13), radius: 15, y: 7)
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }
    private func tabButton(_ symbol: String, _ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 24))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tab == index ? BookXStyle.purple : BookXStyle.ink)
            .frame(maxWidth: .infinity).frame(height: 68)
            .background(tab == index ? BookXStyle.lilac.opacity(0.8) : .clear, in: Capsule())
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: BookLibrary
    var body: some View {
        NavigationStack {
            Form {
                Section("字体大小") { Slider(value: $library.fontSize, in: 14...30, step: 1); Text("\(Int(library.fontSize)) pt") }
                Section("段落行距") { Slider(value: $library.lineSpacing, in: 2...20, step: 1) }
                Section("阅读背景") { Picker("背景", selection: $library.paper) { Text("白色").tag(0); Text("米黄").tag(1); Text("护眼绿").tag(2); Text("深色").tag(3) } }
                Section("翻页方式") { Picker("翻页", selection: $library.pageMode) { Text("左右翻页").tag(0); Text("上下滚动").tag(1) } }
            }
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .onDisappear { library.save() }
        }
    }
}
