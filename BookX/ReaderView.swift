import SwiftUI

struct ReaderView: View {
    let book: BookItem
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var currentPage = 0
    @State private var errorMessage: String?
    @State private var loaded = false

    private var bg: Color {
        switch library.paper {
        case 1: return Color(red: 0.97, green: 0.93, blue: 0.85)
        case 2: return Color(red: 0.86, green: 0.92, blue: 0.85)
        case 3: return Color(red: 0.13, green: 0.13, blue: 0.13)
        default: return .white
        }
    }
    private var ink: Color { library.paper == 3 ? .white : .black }

    // Page lengths are approximate; each page is scrollable to avoid clipping text.
    private var pages: [String] {
        guard !content.isEmpty else { return [""] }
        let length = max(250, Int(800 * 19 / library.fontSize))
        var result: [String] = []
        var start = content.startIndex
        while start < content.endIndex {
            let target = content.index(start, offsetBy: length, limitedBy: content.endIndex) ?? content.endIndex
            let segment = content[start..<target]
            let end: String.Index
            if target != content.endIndex,
               let boundary = segment.lastIndex(where: { $0 == "\n" || $0 == "。" || $0 == "！" || $0 == "？" }),
               content.distance(from: start, to: boundary) > length / 2 {
                end = content.index(after: boundary)
            } else {
                end = target
            }
            result.append(String(content[start..<end]))
            start = end
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3) }
                    .accessibilityLabel("返回书架")
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }.padding()

            if let errorMessage {
                ContentUnavailableView("无法阅读", systemImage: "exclamationmark.book.closed", description: Text(errorMessage))
                Spacer()
            } else if !loaded {
                ProgressView("正在打开书籍").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.pageMode == 0 {
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { i in
                        ScrollView {
                            Text(pages[i])
                                .font(.system(size: library.fontSize))
                                .lineSpacing(library.lineSpacing)
                                .foregroundStyle(ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                        }.tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(pages.indices, id: \.self) { i in
                                Text(pages[i])
                                    .font(.system(size: library.fontSize))
                                    .lineSpacing(library.lineSpacing)
                                    .foregroundStyle(ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24)
                                    .id(i)
                            }
                        }.padding(.vertical, 20)
                    }
                    .onAppear { proxy.scrollTo(currentPage, anchor: .top) }
                    .onChange(of: currentPage) { _, page in
                        withAnimation { proxy.scrollTo(page, anchor: .top) }
                    }
                }
            }

            if loaded && errorMessage == nil {
                HStack {
                    Text("\(currentPage + 1) / \(pages.count)")
                    Spacer()
                    Button { currentPage = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(currentPage == 0)
                    Button { currentPage = min(pages.count - 1, currentPage + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(currentPage >= pages.count - 1)
                }.font(.caption).padding()
            }
        }
        .foregroundStyle(ink)
        .background(bg.ignoresSafeArea())
        .onAppear { loadText() }
        .onChange(of: currentPage) { _, page in
            guard loaded, errorMessage == nil else { return }
            library.updateProgress(book.id, Double(page) / Double(max(1, pages.count - 1)))
        }
        .onDisappear { library.save() }
    }

    private func loadText() {
        let url = library.fileURL(book)
        guard url.pathExtension.lowercased() == "txt" else {
            errorMessage = "当前版本暂不支持 EPUB 正文阅读。"
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
        } else if let text = try? String(contentsOf: url, encoding: .utf16) {
            content = text
        } else if let text = try? String(contentsOf: url, encoding: .gb_18030_2000) {
            content = text
        } else {
            errorMessage = "无法识别 TXT 文件编码。"
            return
        }
        guard !content.isEmpty else {
            errorMessage = "文件没有可阅读的正文。"
            return
        }
        currentPage = min(pages.count - 1, max(0, Int(book.progress * Double(max(1, pages.count - 1)))))
        loaded = true
        library.updateProgress(book.id, Double(currentPage) / Double(max(1, pages.count - 1)))
    }
}

private extension String.Encoding {
    static let gb_18030_2000 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}
