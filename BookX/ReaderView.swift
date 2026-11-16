import SwiftUI

struct ReaderView: View {
    let book: BookItem
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pages: [ReadingPage] = []
    @State private var currentPage = 0
    @State private var visiblePage: Int?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var settings = false
    @State private var documentText: String?

    private var bg: Color {
        switch library.paper {
        case 1: return Color(red: 0.97, green: 0.93, blue: 0.85)
        case 2: return Color(red: 0.86, green: 0.92, blue: 0.85)
        case 3: return Color(red: 0.13, green: 0.13, blue: 0.13)
        default: return .white
        }
    }
    private var ink: Color { library.paper == 3 ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 44, height: 44) }
                    .accessibilityLabel("返回")
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                Spacer()
                Button { settings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                    .accessibilityLabel("阅读设置")
            }.padding(.horizontal)

            if let errorMessage {
                ContentUnavailableView("无法阅读", systemImage: "exclamationmark.book.closed", description: Text(errorMessage))
                Spacer()
            } else if !loaded {
                ProgressView("正在打开书籍").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.pageMode == 0 {
                CurlPageView(pages: pages.map(\.text), currentPage: $currentPage, fontSize: library.fontSize, lineSpacing: library.lineSpacing, ink: ink, background: bg)
                    .id("curl-\(library.paper)-\(library.fontSize)-\(library.lineSpacing)")
            } else if library.pageMode == 1 {
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { i in
                        ScrollView { pageText(i).padding(.vertical, 20) }.tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else if library.pageMode == 2 {
                CoverPageView(pages: pages.map(\.text), currentPage: $currentPage,
                              fontSize: library.fontSize, lineSpacing: library.lineSpacing,
                              ink: ink, background: bg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pages.indices, id: \.self) { i in
                            pageText(i).id(i)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 20)
                }
                .scrollPosition(id: $visiblePage, anchor: .top)
                .onAppear { visiblePage = currentPage }
                .onChange(of: visiblePage) { _, page in
                    if let page, pages.indices.contains(page) { currentPage = page }
                }
            }

            if loaded && errorMessage == nil {
                HStack {
                    Text("\(currentPage + 1) / \(pages.count)").accessibilityIdentifier("reading-position")
                    Spacer()
                    Button { move(to: currentPage - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(currentPage == 0).accessibilityLabel("上一页")
                    Button { move(to: currentPage + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(currentPage >= pages.count - 1).accessibilityLabel("下一页")
                }.font(.caption).padding(.horizontal)
            }
        }
        .foregroundStyle(ink)
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(library.paper == 3 ? .dark : .light)
        .task(id: library.fontSize) { await loadText() }
        .onChange(of: currentPage) { _, _ in savePosition() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition() } }
        .onDisappear { savePosition() }
        .sheet(isPresented: $settings) {
            SettingsView().environmentObject(library).presentationDetents([.medium, .large])
        }
    }

    private func pageText(_ index: Int) -> some View {
        Text(pages[index].text)
            .font(.system(size: library.fontSize))
            .lineSpacing(library.lineSpacing)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
    }
    private func move(to index: Int) {
        let next = max(0, min(pages.count - 1, index))
        if library.pageMode == 3 { visiblePage = next }
        currentPage = next
    }
    private func savePosition() {
        guard loaded, errorMessage == nil, pages.indices.contains(currentPage) else { return }
        library.updateProgress(book.id,
            Double(currentPage) / Double(max(1, pages.count - 1)), offset: pages[currentPage].offset)
    }
    private func loadText() async {
        savePosition()
        loaded = false
        errorMessage = nil
        let url = library.fileURL(book)
        let size = library.fontSize
        do {
            let cached = documentText
            let (text, result) = try await Task.detached(priority: .userInitiated) {
                let text = try cached ?? BookDocumentLoader.load(url).text
                return (text, BookPagination.pages(text, fontSize: size))
            }.value
            guard !Task.isCancelled else { return }
            let saved = library.books.first(where: { $0.id == book.id }) ?? book
            guard !result.isEmpty else { throw BookReadError.invalid("文件没有可阅读的正文。") }
            documentText = text
            pages = result
            if let offset = saved.readingOffset {
                currentPage = BookPagination.pageIndex(for: offset, in: pages)
            } else {
                currentPage = min(pages.count - 1, max(0, Int(saved.progress * Double(max(1, pages.count - 1)))))
            }
            loaded = true
            savePosition()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
