import Foundation

/// Short, bounded inference units. Preserve every character and let the model's
/// text front end handle numbers, punctuation and pronunciation.
enum SpeechText {
    static func segments(_ text: String, limit: Int = 80) -> [String] {
        let limit = max(16, limit)
        var result: [String] = []
        var buffer = ""
        var count = 0
        for character in text {
            buffer.append(character)
            count += 1
            if count >= limit || (count >= 12 && "。！？!?；;\n".contains(character)) {
                result.append(buffer)
                buffer = ""
                count = 0
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// The C inference callback runs outside Swift's task cancellation context.
final class SpeechCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
}

struct SpeechPCM: Sendable {
    let samples: [Float]
    let sampleRate: Int
    /// PCM16 WAV is accepted by AVAudioPlayer on iOS and can be inspected in CI.
    func wav() -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for sample in samples {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            u16(UInt16(bitPattern: Int16(value * 32767)))
        }
        return data
    }
}
