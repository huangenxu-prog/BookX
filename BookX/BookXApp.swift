import SwiftUI
import UniformTypeIdentifiers

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
}

@MainActor
final class BookLibrary: ObservableObject {
    @Published var books: [BookItem] = []
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
        paper = UserDefaults.standard.integer(forKey: "paper")
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
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard ["txt", "epub"].contains(url.pathExtension.lowercased()) else { continue }
            let name = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                books.append(BookItem(id: UUID(), title: url.deletingPathExtension().lastPathComponent, author: "", filename: name, progress: 0, lastRead: nil))
            } catch { print("Book import failed: \(error)") }
        }
        save()
    }
    func fileURL(_ book: BookItem) -> URL { folder.appendingPathComponent(book.filename) }
    func updateProgress(_ id: UUID, _ value: Double) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].progress = value
        books[index].lastRead = Date()
        save()
    }
}

struct RootView: View {
    @EnvironmentObject private var library: BookLibrary
    @State private var tab = 0
    @State private var importer = false
    @State private var settings = false
    @State private var selected: BookItem?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab == 0 ? "书架" : "书库").font(.system(size: 32, weight: .bold))
                Spacer()
                if tab == 0 {
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.title3)
                            .frame(width: 48, height: 48).background(Color(.secondarySystemBackground), in: Circle())
                    }.tint(.primary)
                }
            }.padding(.horizontal, 24).padding(.top, 20)
            ScrollView {
                if tab == 0 {
                    let recent = library.books.filter { $0.lastRead != nil }.sorted { ($0.lastRead ?? .distantPast) > ($1.lastRead ?? .distantPast) }
                    if recent.isEmpty {
                        ContentUnavailableView("还没有阅读记录", systemImage: "books.vertical", description: Text("点击下方 + 导入书籍，从书库开始阅读"))
                            .padding(.top, 80)
                    } else {
                        LazyVStack(spacing: 0) { ForEach(recent) { book in bookRow(book, showProgress: true) } }
                    }
                } else {
                    let sorted = library.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    if sorted.isEmpty {
                        ContentUnavailableView("书库为空", systemImage: "book.closed", description: Text("点击下方 + 导入 TXT 或 EPUB"))
                            .padding(.top, 80)
                    } else {
                        LazyVStack(spacing: 0) { ForEach(sorted) { book in bookRow(book, showProgress: false) } }
                    }
                }
            }.padding(.horizontal, 24)
            HStack(spacing: 10) {
                tabButton("books.vertical.fill", "书架", index: 0)
                Button { importer = true } label: {
                    Image(systemName: "plus").font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 76)
                        .background(Color(red: 0.07, green: 0.07, blue: 0.09), in: Capsule())
                }
                tabButton("book.closed", "书库", index: 1)
            }
            .padding(8).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.gray.opacity(0.25), lineWidth: 0.7))
            .padding(.horizontal, 22).padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .fileImporter(isPresented: $importer, allowedContentTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(library).presentationDetents([.medium, .large]) }
        .fullScreenCover(item: $selected) { book in ReaderView(book: book).environmentObject(library) }
    }
    func tabButton(_ symbol: String, _ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 27))
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(tab == index ? Color.primary : .secondary)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(tab == index ? Color(.secondarySystemBackground) : .clear, in: Capsule())
        }
    }
    func bookRow(_ book: BookItem, showProgress: Bool) -> some View {
        Button { selected = book } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary)
                if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary) }
                if showProgress { Text("已读 \(Int(book.progress * 100))%").font(.caption).foregroundStyle(.secondary) }
                Divider().padding(.top, 10)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
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
