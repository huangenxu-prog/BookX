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
    @State private var menuVisible = false
    @State private var showContents = false
    @State private var document: BookDocument?
    @State private var chapterList: [BookChapter] = []
    @StateObject private var speech = BookSpeech()
    @State private var listening = false

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
            if library.pageMode != 0 || !loaded {
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
            }

            if let errorMessage {
                ContentUnavailableView("无法阅读", systemImage: "exclamationmark.book.closed", description: Text(errorMessage))
                Spacer()
            } else if !loaded {
                ProgressView("正在打开书籍").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.pageMode == 0 {
                CurlPageView(pages: pages, currentPage: $currentPage, fontSize: library.fontSize, lineSpacing: library.lineSpacing, ink: ink, background: bg)
                    .id("curl-\(library.paper)-\(library.fontSize)-\(library.lineSpacing)")
                    .ignoresSafeArea(edges: .vertical)
                    .overlay(alignment: .center) {
                        // Only the small central tap target opens the menu; page turns stay independent.
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 64, height: 64)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { menuVisible.toggle() } }
                            .accessibilityLabel("阅读菜单")
                    }
            } else if library.pageMode == 1 {
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { i in
                        ScrollView { pageText(i).padding(.vertical, 20) }.tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else if library.pageMode == 2 {
                CoverPageView(pages: pages, currentPage: $currentPage,
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

            if loaded && errorMessage == nil && library.pageMode != 0 {
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
        .onDisappear { savePosition(); library.save(); speech.stop(); listening = false }
        .overlay(alignment: .top) {
            if loaded && library.pageMode == 0 {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    Spacer()
                    Text(book.title).font(.subheadline).lineLimit(1)
                    Spacer()
                    Button { settings = true } label: { Text("aA").frame(width: 44, height: 44) }
                }
                .padding(.horizontal, 14)
                .foregroundStyle(ink)
            }
        }
        .overlay(alignment: .bottom) {
            if loaded && library.pageMode == 0 {
                Text("\(currentPage + 1) / \(pages.count)")
                    .font(.caption).foregroundStyle(ink.opacity(0.65))
                    .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottom) {
            if loaded && menuVisible {
                HStack(spacing: 26) {
                    Button { showContents = true } label: {
                        Label("目录", systemImage: "list.bullet").frame(maxWidth: .infinity)
                    }
                    Button { settings = true } label: {
                        Label("排版", systemImage: "textformat.size").frame(maxWidth: .infinity)
                    }
                    Button { toggleListening() } label: {
                        Label(listening ? "停止听书" : "听书", systemImage: listening ? "stop.fill" : "headphones").frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .padding(18)
                .foregroundStyle(ink)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 24)
                .padding(.bottom, 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if listening && loaded {
                HStack(spacing: 16) {
                    Image(systemName: "headphones")
                    Text("正在听书").font(.subheadline)
                    Spacer()
                    Button { speech.togglePause() } label: {
                        Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(speech.isPaused ? "继续朗读" : "暂停朗读")
                    Button { speech.stop(); listening = false } label: {
                        Image(systemName: "stop.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel("停止听书")
                }
                .padding(.horizontal, 20)
                .foregroundStyle(ink)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 112)
            }
        }
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

    private func toggleListening() {
        if listening {
            speech.stop()
            listening = false
        } else if loaded && pages.indices.contains(currentPage) {
            listening = true
            menuVisible = false
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
        library.updateProgress(book.id,
            Double(currentPage) / Double(max(1, pages.count - 1)), offset: pages[currentPage].offset)
    }
    private func loadText() async {
        speech.stop()
        listening = false
        savePosition()
        loaded = false
        errorMessage = nil
        let url = library.fileURL(book)
        let size = library.fontSize
        do {
            let cached = document ?? library.cachedDocument(for: book.id)
            // A rapid font slider drag should not start a full-book pagination for every tick.
            if cached != nil { try await Task.sleep(nanoseconds: 120_000_000) }
            try Task.checkCancellation()
            let (parsed, result) = try await Task.detached(priority: .userInitiated) {
                let parsed = try cached ?? BookDocumentLoader.load(url)
                return (parsed, BookPagination.pages(parsed.text, fontSize: size))
            }.value
            guard !Task.isCancelled else { return }
            let saved = library.books.first(where: { $0.id == book.id }) ?? book
            guard !result.isEmpty else { throw BookReadError.invalid("文件没有可阅读的正文。") }
            document = parsed
            library.cacheDocument(parsed, for: book.id)
            chapterList = parsed.chapters
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
