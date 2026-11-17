import Foundation

struct BookItem: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var filename: String
    var progress: Double
    var lastRead: Date?
    var readingOffset: Int?
    var hiddenFromShelf: Bool?
    var epubLocation: EPUBLocation?
}

