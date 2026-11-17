import XCTest
@testable import BookXCore

final class SpeechTests: XCTestCase {
    func testSegmentsKeepUnicodeNumbersAndPunctuation() {
        let text = String(repeating: "秦牧说：“今天是2026年11月17日，价格3.14元。”👨‍👩‍👧‍👦\n下一段继续。", count: 20)
        let segments = SpeechText.segments(text)
        XCTAssertEqual(segments.joined(), text)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 80 })
        XCTAssertTrue(SpeechText.segments(" \n\t ").isEmpty)
        XCTAssertEqual(SpeechText.segments("短句。"), ["短句。"])
    }
    func testSpeechSegmentsPreferNaturalSentenceAndClauseBreaks() {
        let sentence = "这是一个很长的故事，主人公正在穿过山谷，忽然听见远处传来一阵脚步声。随后，他停下脚步，认真观察四周。"
        let segments = SpeechText.segments(sentence, limit: 40)
        XCTAssertEqual(segments.joined(), sentence)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 40 })
        XCTAssertTrue(segments.first?.hasSuffix("，") == true || segments.first?.hasSuffix("。") == true)
        let unpunctuated = String(repeating: "山", count: 95)
        XCTAssertEqual(SpeechText.segments(unpunctuated).joined(), unpunctuated)
        XCTAssertTrue(SpeechText.segments(unpunctuated).allSatisfy { $0.count <= 80 })
    }
    func testWavHeaderClipsNonFiniteSamplesSafely() {
        let data = SpeechPCM(samples: [0, 1, -1, .nan, .infinity, 2], sampleRate: 24000).wav()
        XCTAssertEqual(data.count, 56)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(Array(data[44..<48]), [0, 0, 255, 127])
    }
    func testCancellationBeforeLoadDoesNotAllocateModel() async {
        let engine = KokoroVoiceEngine(resources: URL(fileURLWithPath: "/missing"))
        let cancellation = SpeechCancellation()
        cancellation.cancel()
        do { _ = try await engine.synthesize("取消的文字", cancellation: cancellation); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error)") }
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)
    }
    func testMissingModelFailsClearlyWithoutSystemVoiceFallback() async {
        let engine = KokoroVoiceEngine(resources: URL(fileURLWithPath: "/missing"))
        do { _ = try await engine.synthesize("测试", cancellation: SpeechCancellation()); XCTFail("Expected missing resource error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("缺少")) }
    }
    func testRealKokoroMandarinSynthesisAndSessionLifetime() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOOKX_TTS_MODEL_DIR"] else {
            throw XCTSkip("Set BOOKX_TTS_MODEL_DIR to run native inference")
        }
        let engine = KokoroVoiceEngine(resources: URL(fileURLWithPath: path))
        let initiallyLoaded = await engine.isLoaded
        XCTAssertFalse(initiallyLoaded)
        let token = SpeechCancellation()
        let start = Date()
        let pcm = try await engine.synthesize("清晨，阳光落在书页上。秦牧翻开书，轻声说道：今天是2026年11月17日，我们继续阅读。", cancellation: token)
        XCTAssertEqual(pcm.sampleRate, 24000)
        XCTAssertGreaterThan(pcm.samples.count, pcm.sampleRate)
        XCTAssertTrue(pcm.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(pcm.samples.map { abs($0) }.max() ?? 0, 0.001)
        print("BOOKX_TTS macOS cold load + synthesis: \(Date().timeIntervalSince(start))s; audio: \(Double(pcm.samples.count) / Double(pcm.sampleRate))s")
        if let output = ProcessInfo.processInfo.environment["BOOKX_TTS_SAMPLE"] {
            try pcm.wav().write(to: URL(fileURLWithPath: output))
        }
        let newer = SpeechCancellation()
        _ = try await engine.synthesize("下一段继续。", cancellation: newer)
        let inFlight = Task { try await engine.synthesize(String(repeating: "正在朗读的内容。", count: 6), cancellation: newer) }
        try await Task.sleep(nanoseconds: 10_000_000)
        newer.cancel()
        do { _ = try await inFlight.value; XCTFail("Cancelled inference returned audio") }
        catch is CancellationError { }
        await engine.release(session: token.id)
        let retained = await engine.isLoaded
        XCTAssertTrue(retained, "An old session must not release the active model")
        await engine.release(session: newer.id)
        let released = await engine.isLoaded
        XCTAssertFalse(released)
    }
}
