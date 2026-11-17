import SwiftUI

struct ReaderView: View {
    let book: BookItem
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pages: [ReadingPage] = []
    @State private var currentPage = 0
    @State private var visibleLocation: EPUBLocation?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var settings = false
    @State private var showContents = false
    @State private var document: BookDocument?
    @State private var chapterList: [BookChapter] = []
    @State private var paginationTask: Task<Void, Never>?
    @State private var paginationGeneration = UUID()
    @State private var isPreviewPagination = false
    @State private var epubIndex: EPUBResourceIndex?
    @State private var epubWindow: [Int: EPUBChapterPages] = [:]
    @State private var epubLayout: ReadingLayout?
    @State private var chapterTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var chapterError: String?
    @State private var resolvedNeighbors: [Int: Set<Int>] = [:]
    @State private var windowRevision = UUID()

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
                CurlPageView(pages: pages, currentPage: $currentPage, fontSize: library.fontSize, lineSpacing: library.lineSpacing, ink: ink, background: bg, header: AnyView(readerHeader), topInset: curlTopInset, bottomInset: curlBottomInset, contentID: windowRevision, positionLabels: pages.indices.map(positionLabel))
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
                        ForEach(pages, id: \.location) { page in
                            pageText(page.text).id(page.location)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 20)
                }
                .scrollPosition(id: $visibleLocation, anchor: .top)
                .onAppear { if pages.indices.contains(currentPage) { visibleLocation = pages[currentPage].location } }
                .onChange(of: visibleLocation) { _, location in
                    if let page = pages.firstIndex(where: { $0.location == location }) { currentPage = page }
                }
            }

            }
            .task(id: "\(Int(geometry.size.width))-\(Int(geometry.size.height))-\(library.fontSize)-\(library.lineSpacing)-\(library.pageMode)") {
                await loadText(pageSize: geometry.size)
            }
            }

            if library.pageMode != 0 {
                HStack {
                    Text(positionLabel(currentPage)).accessibilityIdentifier("reading-position")
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
        .onChange(of: currentLocation) { _, _ in
            savePosition()
            if epubIndex != nil { prefetchChapters() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition(); library.save() } }
        .onDisappear { chapterTask?.cancel(); prefetchTask?.cancel(); paginationTask?.cancel(); paginationGeneration = UUID(); savePosition(); library.save() }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                Group {
                    if chapterList.isEmpty {
                        ContentUnavailableView("暂无章节目录", systemImage: "list.bullet.rectangle", description: Text("此书没有可识别的章节标题。"))
                    } else {
                        List(chapterList.indices, id: \.self) { index in
                            Button {
                                if epubIndex != nil { jumpToChapter(index) }
                                else { move(to: BookPagination.pageIndex(for: chapterList[index].offset, in: pages)) }
                                showContents = false
                            } label: {
                                HStack {
                                    Text(chapterList[index].title).lineLimit(2)
                                    Spacer()
                                    if isCurrentChapter(index) {
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
        .alert("章节加载失败", isPresented: Binding(get: { chapterError != nil }, set: { if !$0 { chapterError = nil } })) {
            Button("重试") { chapterError = nil; prefetchChapters() }
            Button("取消", role: .cancel) { chapterError = nil }
        } message: { Text(chapterError ?? "") }
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

                } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("阅读功能")
            }.padding(.horizontal)
    }

    private func pageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: library.fontSize))
            .lineSpacing(library.lineSpacing)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
    }
    private func move(to index: Int) {
        let next = max(0, min(pages.count - 1, index))
        if library.pageMode == 3, pages.indices.contains(next) { visibleLocation = pages[next].location }
        currentPage = next
    }
    private var currentLocation: EPUBLocation? {
        pages.indices.contains(currentPage) ? pages[currentPage].location : nil
    }
    private func savePosition() {
        guard loaded, errorMessage == nil, pages.indices.contains(currentPage) else { return }
        let absoluteOffset = pages[currentPage].offset
        if let index = epubIndex, let resource = pages[currentPage].resourceIndex {
            let length = max(1, epubWindow[resource]?.length ?? 1)
            let fraction = (Double(resource) + Double(absoluteOffset) / Double(length)) / Double(max(1, index.resources.count))
            library.updateProgress(book.id, fraction, offset: absoluteOffset,
                                   epubLocation: EPUBLocation(resource: resource, offset: absoluteOffset))
            return
        }
        let fraction = document.map { Double(absoluteOffset) / Double(max(1, $0.text.utf16.count)) }
            ?? Double(currentPage) / Double(max(1, pages.count - 1))
        library.updateProgress(book.id, fraction, offset: absoluteOffset)
    }
    private func loadText(pageSize: CGSize) async {
        guard pageSize.width > 48, pageSize.height > 40 else { return }
        chapterTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        paginationTask?.cancel()
        paginationTask = nil
        paginationGeneration = UUID()
        savePosition()
        loaded = false
        errorMessage = nil
        chapterError = nil
        let url = library.fileURL(book)
        let size = library.fontSize
        let spacing = library.lineSpacing
        let screenPages = library.pageMode == 0 || library.pageMode == 1
        let textSize = library.pageMode == 0
            ? CGSize(width: pageSize.width, height: pageSize.height - CurlPageView.headerHeight - CurlPageView.footerHeight - curlTopInset - curlBottomInset)
            : pageSize
        let layoutKey = screenPages ? "screen-\(Int(textSize.width))-\(Int(textSize.height))-\(size)-\(spacing)" : "flow-\(size)"
        if url.pathExtension.lowercased() == "epub" {
            let layout = ReadingLayout(size: textSize, font: size, spacing: spacing, paged: screenPages)
            await openEPUB(layout: layout)
            return
        }
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
            let (parsed, result, partial) = try await readerWorker {
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
            }
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
                        let worker = Task.detached(priority: .utility) {
                            let result = try screenPages
                                ? ScreenPagination.pages(parsed.text, size: textSize, fontSize: size, lineSpacing: spacing)
                                : BookPagination.pages(parsed.text, fontSize: size)
                            try Task.checkCancellation()
                            BookPageStore.save(result, source: url, key: layoutKey)
                            return result
                        }
                        full = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: {
                            worker.cancel()
                        }
                    } catch { full = nil }
                    guard !Task.isCancelled, generation == paginationGeneration,
                          let full, !full.isEmpty else { return }
                    // Preserve the exact reading location while replacing preview pages.
                    let position = pages.indices.contains(currentPage) ? pages[currentPage].offset : (savedOffset ?? 0)
                    library.cachePages(full, for: book.id, key: layoutKey)
                    pages = full
                    windowRevision = UUID()
                    currentPage = BookPagination.pageIndex(for: position, in: full)
                    if library.pageMode == 3 { visibleLocation = full[currentPage].location }
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
        windowRevision = UUID()
        if let offset = saved.readingOffset {
            currentPage = BookPagination.pageIndex(for: offset, in: pages)
        } else {
            currentPage = min(pages.count - 1, max(0, Int(saved.progress * Double(max(1, pages.count - 1)))))
        }
        loaded = true
        savePosition()
    }

    private func positionLabel(_ page: Int) -> String {
        guard pages.indices.contains(page), let resource = pages[page].resourceIndex,
              let index = epubIndex, let chapter = epubWindow[resource] else {
            return "\(page + 1) / \(pages.count)"
        }
        let local = BookPagination.pageIndex(for: pages[page].offset, in: chapter.pages)
        return "\(resource + 1)/\(index.resources.count)章 · \(local + 1)/\(chapter.pages.count)页"
    }
    private func isCurrentChapter(_ index: Int) -> Bool {
        guard pages.indices.contains(currentPage) else { return false }
        if epubIndex != nil { return pages[currentPage].resourceIndex == index }
        return chapterList[index].offset <= pages[currentPage].offset &&
            (index + 1 == chapterList.count || chapterList[index + 1].offset > pages[currentPage].offset)
    }
    private func openEPUB(layout: ReadingLayout, destination: EPUBLocation? = nil) async {
        let generation = paginationGeneration
        let url = library.fileURL(book)
        let saved = library.books.first(where: { $0.id == book.id }) ?? book
        let existingIndex = epubIndex
        do {
            let (index, location, chapter) = try await readerWorker {
                let index = try existingIndex ?? EPUBResourceStore.index(url)
                let location: EPUBLocation
                if let explicit = destination ?? saved.epubLocation { location = explicit }
                else if let offset = saved.readingOffset {
                    location = try EPUBReadingEngine.legacyLocation(url, index: index, offset: offset)
                } else {
                    location = EPUBLocation(resource: min(index.resources.count - 1,
                        Int(saved.progress * Double(index.resources.count))), offset: 0)
                }
                let target = max(0, min(index.resources.count - 1, location.resource))
                let forward = try EPUBReadingEngine.readableChapter(url, index: index, startingAt: target, direction: 1, layout: layout)
                let chapter = try forward ?? EPUBReadingEngine.readableChapter(url, index: index, startingAt: target - 1, direction: -1, layout: layout)
                guard let chapter else { throw BookReadError.invalid("书籍没有可阅读的文字正文。") }
                return (index, location, chapter)
            }
            guard !Task.isCancelled, generation == paginationGeneration else { return }
            epubIndex = index
            epubLayout = layout
            document = nil
            epubWindow = [chapter.resource: chapter]
            resolvedNeighbors = [:]
            chapterList = index.resources.enumerated().map {
                BookChapter(title: $0.element.title ?? "第\($0.offset + 1)章", offset: $0.offset)
            }
            pages = chapter.pages
            currentPage = BookPagination.pageIndex(for: chapter.resource == location.resource ? location.offset : 0, in: pages)
            visibleLocation = pages[currentPage].location
            windowRevision = UUID()
            loaded = true
            savePosition()
            prefetchChapters()
        } catch {
            guard !Task.isCancelled, generation == paginationGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func jumpToChapter(_ resource: Int) {
        guard let layout = epubLayout else { return }
        savePosition()
        chapterTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        paginationGeneration = UUID()
        speech.stop(); listening = false
        loaded = false; errorMessage = nil; chapterError = nil
        chapterTask = Task { await openEPUB(layout: layout, destination: EPUBLocation(resource: resource, offset: 0)) }
    }
    private func prefetchChapters() {
        guard let index = epubIndex, let layout = epubLayout,
              pages.indices.contains(currentPage), let resource = pages[currentPage].resourceIndex else { return }
        // Don't cancel and restart on every page within the same chapter.
        if prefetchTask != nil { return }
        let generation = paginationGeneration
        let url = library.fileURL(book)
        let loadedResources = Set(epubWindow.keys)
        prefetchTask = Task {

            do {
                for direction in [1, -1] {
                    let target = resource + direction
                    guard index.resources.indices.contains(target), !loadedResources.contains(target),
                          resolvedNeighbors[resource]?.contains(direction) != true else { continue }
                    let chapter = try await readerWorker(priority: .utility) {
                        try EPUBReadingEngine.readableChapter(url, index: index, startingAt: target,
                                                             direction: direction, layout: layout)
                    }
                    guard !Task.isCancelled, generation == paginationGeneration else { return }
                    resolvedNeighbors[resource, default: []].insert(direction)
                    if let chapter { extendWindow(chapter) }
                }
                    } catch {
                guard !Task.isCancelled, generation == paginationGeneration else { return }
                chapterError = error.localizedDescription
            }
            guard generation == paginationGeneration else { return }
            prefetchTask = nil
            // Schedule the next neighborhood only after releasing this task's slot.
            if chapterError == nil, pages.indices.contains(currentPage), pages[currentPage].resourceIndex != resource {
                prefetchChapters()
            }
        }
    }
    private func extendWindow(_ chapter: EPUBChapterPages) {
        guard pages.indices.contains(currentPage), let resource = pages[currentPage].resourceIndex else { return }
        let anchor = EPUBLocation(resource: resource, offset: pages[currentPage].offset)
        let updated = EPUBWindow.adding(chapter, to: epubWindow, anchor: anchor)
        if !Set(epubWindow.keys).isSubset(of: Set(updated.chapters.keys)) { resolvedNeighbors = [:] }
        epubWindow = updated.chapters
        pages = updated.pages
        currentPage = updated.selected
        // Stable resource/offset IDs keep scrolling anchored when a chapter is prepended.
        windowRevision = UUID()
    }

}
