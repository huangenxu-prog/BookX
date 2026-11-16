import SwiftUI

struct ReaderView: View {
    let book: BookItem
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var currentPage = 0
    private var bg: Color {
        switch library.paper {
        case 1: return Color(red: 0.97, green: 0.93, blue: 0.85)
        case 2: return Color(red: 0.86, green: 0.92, blue: 0.85)
        case 3: return Color(red: 0.13, green: 0.13, blue: 0.13)
        default: return .white
        }
    }
    private var ink: Color { library.paper == 3 ? .white : .black }
    private var pages: [String] {
        guard !content.isEmpty else { return [""] }
        let size = max(300, Int(900 * 19 / library.fontSize))
        var result: [String] = []
        var start = content.startIndex
        while start < content.endIndex {
            let end = content.index(start, offsetBy: size, limitedBy: content.endIndex) ?? content.endIndex
            result.append(String(content[start..<end]))
            start = end
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3) }
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }.padding()
            if library.pageMode == 0 {
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
                }.tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                ScrollView {
                    Text(content).font(.system(size: library.fontSize))
                        .lineSpacing(library.lineSpacing).foregroundStyle(ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }
            HStack {
                Text("\(currentPage + 1) / \(pages.count)")
                Spacer()
                Button { if currentPage > 0 { currentPage -= 1 } } label: { Image(systemName: "chevron.left") }
                Button { if currentPage + 1 < pages.count { currentPage += 1 } } label: { Image(systemName: "chevron.right") }
            }.font(.caption).padding()
        }
        .foregroundStyle(ink).background(bg.ignoresSafeArea())
        .onAppear { loadText() }
        .onChange(of: currentPage) { _, value in
            library.updateProgress(book.id, Double(value) / Double(max(1, pages.count - 1)))
        }
    }
    private func loadText() {
        let url = library.fileURL(book)
        guard url.pathExtension.lowercased() == "txt" else {
            content = "EPUB 文件已导入。EPUB 正文解析模块尚未接入。"
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) { content = text }
        else if let text = try? String(contentsOf: url, encoding: .utf16) { content = text }
        else { content = "无法读取文件编码。" }
        currentPage = min(pages.count - 1, max(0, Int(book.progress * Double(max(1, pages.count - 1)))))
        library.updateProgress(book.id, Double(currentPage) / Double(max(1, pages.count - 1)))
    }
}
