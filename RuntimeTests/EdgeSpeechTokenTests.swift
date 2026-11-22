import XCTest
@testable import BookX

final class EdgeSpeechTokenTests: XCTestCase {
    func testVersionTwoTokenMatchesIndependentReference() {
        // Cross-checked with the public Edge TTS v2 CS64 + SHA256 implementation.
        // Network calls are deliberately excluded: this must be deterministic.
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(
            EdgeSpeech.signatureV2(at: date),
            "FDA8112B8756B195-BA3F4ED428AF8E21948543EAD66D831CEAAFE0A00E5471312ECDDC3C7422E611"
        )
    }
}
