import Foundation
import ReadiumZIPFoundation

/// Shared by the application and its macOS tests, using the same archive API.
struct EPUBArchive {
    private let archive: Archive

    init(url: URL) async throws {
        try Task.checkCancellation()
        archive = try await Archive(url: url, accessMode: .read)
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        guard let entry = try await archive.get(path), entry.type == .file else {
            throw BookReadError.invalid("EPUB 缺少文件：\(path)")
        }
        guard entry.uncompressedSize <= limit else {
            throw BookReadError.invalid("EPUB 文件过大：\(path)")
        }
        let buffer = ArchiveBuffer(limit: limit)
        _ = try await archive.extract(entry) { chunk in
            try Task.checkCancellation()
            try await buffer.append(chunk)
        }
        try Task.checkCancellation()
        return await buffer.data
    }
}

private actor ArchiveBuffer {
    let limit: Int
    private(set) var data = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else {
            throw BookReadError.invalid("EPUB 解压后的文件过大。")
        }
        data.append(chunk)
    }
}
