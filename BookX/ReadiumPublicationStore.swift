import Foundation
import ReadiumShared
import ReadiumStreamer

/// Owns the Readium publication and its lazy resource container for the active book.
/// Rendering stays behind the curl compatibility check.
actor ReadiumPublicationStore {
    static let shared = ReadiumPublicationStore()
    private var source: URL?
    private var signature: String?
    private var publication: Publication?

    func open(_ url: URL) async throws -> Publication {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if source == url, signature == stamp, let publication { return publication }
        guard let file = FileURL(url: url) else {
            throw BookReadError.invalid("EPUB 文件地址无效。")
        }
        let retriever = AssetRetriever(httpClient: DefaultHTTPClient())
        let asset = try await retriever.retrieve(url: file).get()
        let result = try await PublicationOpener(parser: EPUBParser())
            .open(asset: asset, allowUserInteraction: false).get()
        try Task.checkCancellation()
        guard !result.readingOrder.isEmpty, !result.isRestricted else {
            throw BookReadError.invalid("EPUB 没有可读取的章节或需要授权。")
        }
        source = url
        signature = stamp
        publication = result
        return result
    }

    func index(_ url: URL) async throws -> EPUBResourceIndex {
        let publication = try await open(url)
        var titles: [String: String] = [:]
        func collect(_ links: [Link]) {
            for link in links {
                if let title = link.title { titles[path(link)] = title }
                collect(link.children)
            }
        }
        collect(publication.manifest.tableOfContents)
        return EPUBResourceIndex(
            title: publication.metadata.title ?? "",
            author: publication.metadata.authors.map(\.name).joined(separator: "、"),
            resources: publication.readingOrder.map {
                EPUBResource(path: path($0), title: titles[path($0)] ?? $0.title)
            }
        )
    }

    private func path(_ link: Link) -> String {
        let href = link.url().string
        let value = String(href.split(separator: "#", maxSplits: 1).first ?? "")
        return (value.removingPercentEncoding ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
