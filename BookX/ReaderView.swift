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
    @State private var showContents = false
    @State private var document: BookDocument?
    @State private var chapterList: [BookChapter] = []
    @StateObject private var speech = BookSpeech()
    @State private var listening = false
    @State private var paginationTask: Task<Void, Never>?
    @State private var paginationGeneration = UUID()
    @State private var isPreviewPagination = false

    private var bg: Color {
        switch library.paper {
        case 1: return Color(red: 0.97, green: 0.93, blue: 0.85)
        case 2: return Color(red: 0.86, green: 0.92, blue: 0.85)
        case 3: return Color(red: 0.13, green: 0.13, blue: 0.13)
        default: return .white
        }
    }
    private var ink: Color { library.paper == 3 ? .white : .black }
    // The curl controller must fill the physical screen; keep controls inside safe bounds.
    // Avoid counting the safe-area gap twice inside the full-screen curl sheet.
    private var curlTopInset: CGFloat { screenSafeInsets.top + 4 }
    private var curlBottomInset: CGFloat { max(0, screenSafeInsets.bottom - 12) }
    private var screenSafeInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }


    var body: some View {
        VStack(spacing: 0) {
            if library.pageMode != 0 { readerHeader }


            GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
            if let errorMessage {
                VStack(spacing: 0) {
                    if library.pageMode == 0 { readerHeader }
                    ContentUnavailableView("无法阅读", systemImage: "exclamationmark.book.closed", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if !loaded {
                VStack(spacing: 0) {
                    if library.pageMode == 0 { readerHeader }
                    ProgressView("正在打开书籍").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if library.pageMode == 0 {
                CurlPageView(pages: pages, currentPage: $currentPage, fontSize: library.fontSize, lineSpacing: library.lineSpacing, ink: ink, background: bg, header: AnyView(readerHeader), topInset: curlTopInset, bottomInset: curlBottomInset)
                    .id("curl-\(library.paper)-\(library.fontSize)-\(library.lineSpacing)")
                    .clipped()
            } else if library.pageMode == 1 {
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { i in
                        ScreenPageView(text: pages[i].text, fontSize: library.fontSize, lineSpacing: library.lineSpacing, ink: ink).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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

            }
            .task(id: "\(Int(geometry.size.width))-\(Int(geometry.size.height))-\(library.fontSize)-\(library.lineSpacing)-\(library.pageMode)") {
                await loadText(pageSize: geometry.size)
            }
            }

            if library.pageMode != 0 {
                HStack {
                    Text("\(currentPage + 1) / \(pages.count)").accessibilityIdentifier("reading-position")
                    Spacer()
                    Button { move(to: currentPage - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(currentPage == 0).accessibilityLabel("上一页")
                    Button { move(to: currentPage + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(currentPage >= pages.count - 1).accessibilityLabel("下一页")
                }.font(.caption).padding(.horizontal)
                    .opacity(loaded ? 1 : 0)
                    .disabled(!loaded)
            }
        }
        .foregroundStyle(ink)
        .ignoresSafeArea(edges: library.pageMode == 0 ? .vertical : [])
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(library.paper == 3 ? .dark : .light)
        .onChange(of: currentPage) { _, _ in
            savePosition()
            if listening && pages.indices.contains(currentPage) {
                speech.play(pages[currentPage].text, page: currentPage)
            }
        }
        .onChange(of: speech.finishedPage) { _, page in
            guard listening, let page, page == currentPage else { return }
            if pages.indices.contains(page + 1) {
                move(to: page + 1)
            } else {
                listening = false
                speech.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition(); library.save() } }
        .onDisappear { paginationTask?.cancel(); paginationGeneration = UUID(); savePosition(); library.save(); speech.stop(); listening = false }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                Group {
                    if chapterList.isEmpty {
                        ContentUnavailableView("暂无章节目录", systemImage: "list.bullet.rectangle", description: Text("此书没有可识别的章节标题。"))
                    } else {
                        List(chapterList.indices, id: \.self) { index in
                            Button {
                                move(to: BookPagination.pageIndex(for: chapterList[index].offset, in: pages))
                                showContents = false
                            } label: {
                                HStack {
                                    Text(chapterList[index].title).lineLimit(2)
                                    Spacer()
                                    if pages.indices.contains(currentPage), chapterList[index].offset <= pages[currentPage].offset && (index + 1 == chapterList.count || chapterList[index + 1].offset > pages[currentPage].offset) {
                                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                    .navigationTitle("目录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $settings) {
            SettingsView().environmentObject(library).presentationDetents([.medium, .large])
        }
    }

    private var readerHeader: some View {
        HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 44, height: 44) }
                    .accessibilityLabel("返回")
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                Spacer()
                Menu {
                    Button { showContents = true } label: {
                        Label("目录", systemImage: "list.bullet")
                    }.disabled(!loaded)
                    Button { settings = true } label: {
                        Label("排版", systemImage: "textformat.size")
                    }
                    if listening {
                        Button { speech.togglePause() } label: {
                            Label(speech.isPaused ? "继续听书" : "暂停听书", systemImage: speech.isPaused ? "play.fill" : "pause.fill")
                        }
                        Button { toggleListening() } label: {
                            Label("停止听书", systemImage: "stop.fill")
                        }
                    } else {
                        Button { toggleListening() } label: {
                            Label("听书", systemImage: "headphones")
                        }.disabled(!loaded)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("阅读功能")
            }.padding(.horizontal)
    }

    private func toggleListening() {
        if listening {
            speech.stop()
            listening = false
        } else if loaded && pages.indices.contains(currentPage) {
            listening = true
            speech.play(pages[currentPage].text, page: currentPage)
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
        let absoluteOffset = pages[currentPage].offset
        let fraction = document.map { Double(absoluteOffset) / Double(max(1, $0.text.count)) }
            ?? Double(currentPage) / Double(max(1, pages.count - 1))
        library.updateProgress(book.id, fraction, offset: absoluteOffset)
    }
    private func loadText(pageSize: CGSize) async {
        guard pageSize.width > 48, pageSize.height > 40 else { return }
        paginationTask?.cancel()
        paginationTask = nil
        paginationGeneration = UUID()
        speech.stop()
        listening = false
        savePosition()
        loaded = false
        errorMessage = nil
        let url = library.fileURL(book)
        let size = library.fontSize
        let spacing = library.lineSpacing
        let screenPages = library.pageMode == 0 || library.pageMode == 1
        let textSize = library.pageMode == 0
            ? CGSize(width: pageSize.width, height: pageSize.height - CurlPageView.headerHeight - CurlPageView.footerHeight - curlTopInset - curlBottomInset)
            : pageSize
        let layoutKey = screenPages ? "screen-\(Int(textSize.width))-\(Int(textSize.height))-\(size)-\(spacing)" : "flow-\(size)"
        do {
            let cached = document ?? library.cachedDocument(for: book.id)
            if let cached, let ready = library.cachedPages(for: book.id, key: layoutKey) {
                install(cached, pages: ready)
                return
            }
            // A rapid font slider drag should not start a full-book pagination for every tick.
            if cached != nil { try await Task.sleep(nanoseconds: 120_000_000) }
            try Task.checkCancellation()
            // Read cached layouts immediately; otherwise paginate only a short
            // neighborhood around the saved position before showing the reader.
            let saved = library.books.first(where: { $0.id == book.id }) ?? book
            let savedOffset = saved.readingOffset
            let (parsed, result, partial) = try await Task.detached(priority: .userInitiated) {
                let parsed = try cached ?? BookDocumentStore.load(url)
                if let ready = BookPageStore.load(url, key: layoutKey) {
                    return (parsed, ready, false)
                }
                let source = parsed.text as NSString
                let target = max(0, min(source.length, savedOffset ?? Int(saved.progress * Double(source.length))))
                // A little context before the bookmark allows backwards page turns.
                let start = max(0, target - 800)
                let window = source.rangeOfComposedCharacterSequences(for:
                    NSRange(location: start, length: min(8000, source.length - start)))
                let fragment = source.substring(with: window)
                let local = try screenPages
                    ? ScreenPagination.pages(fragment, size: textSize, fontSize: size, lineSpacing: spacing)
                    : BookPagination.pages(fragment, fontSize: size)
                let preview = local.map { ReadingPage(offset: window.location + $0.offset, text: $0.text) }
                return (parsed, preview, true)
            }.value
            guard !Task.isCancelled else { return }
            guard !result.isEmpty else { throw BookReadError.invalid("文件没有可阅读的正文。") }
            library.cacheDocument(parsed, for: book.id)
            if !partial { library.cachePages(result, for: book.id, key: layoutKey) }
            isPreviewPagination = partial
            install(parsed, pages: result)
            if partial {
                let generation = paginationGeneration
                paginationTask = Task {
                    // Let the first visible pages settle before full-book background work.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, generation == paginationGeneration else { return }
                    // Run the expensive complete layout off the main actor.
                    let full: [ReadingPage]?
                    do {
                        full = try await Task.detached(priority: .utility) {
                            let result = try screenPages
                                ? ScreenPagination.pages(parsed.text, size: textSize, fontSize: size, lineSpacing: spacing)
                                : BookPagination.pages(parsed.text, fontSize: size)
                            if !Task.isCancelled { BookPageStore.save(result, source: url, key: layoutKey) }
                            return result
                        }.value
                    } catch { full = nil }
                    guard !Task.isCancelled, generation == paginationGeneration,
                          let full, !full.isEmpty else { return }
                    // Preserve the exact reading location while replacing preview pages.
                    let position = pages.indices.contains(currentPage) ? pages[currentPage].offset : (savedOffset ?? 0)
                    library.cachePages(full, for: book.id, key: layoutKey)
                    pages = full
                    currentPage = BookPagination.pageIndex(for: position, in: full)
                    isPreviewPagination = false
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func install(_ parsed: BookDocument, pages result: [ReadingPage]) {
        let saved = library.books.first(where: { $0.id == book.id }) ?? book
        document = parsed
        chapterList = parsed.chapters
        pages = result
        if let offset = saved.readingOffset {
            currentPage = BookPagination.pageIndex(for: offset, in: pages)
        } else {
            currentPage = min(pages.count - 1, max(0, Int(saved.progress * Double(max(1, pages.count - 1)))))
        }
        loaded = true
        savePosition()
    }

}
