import Foundation

enum EPUBReader {
    static func read(url: URL) async throws -> String {
        try await BookDocumentLoader.load(url).text
    }
}
