import Foundation
import CryptoKit

/// Optional online voice source. It is deliberately isolated from the reading
/// engine: endpoint or token changes must never prevent offline reading.
enum EdgeSpeech {
    enum Failure: LocalizedError {
        case timeout
        case emptyAudio
        case invalidFrame
        var errorDescription: String? {
            switch self {
            case .timeout: return "在线朗读连接超时"
            case .emptyAudio: return "在线朗读没有返回音频"
            case .invalidFrame: return "在线朗读返回的音频数据无效"
            }
        }
    }

    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromium = "143.0.3650.75"
    private static let copyright = "Copyright (C) Microsoft Corporation. All rights reserved."

    /// v2 signature as verified against rany2/edge-tts' CS64 + SHA256 algorithm.
    /// The SHA256 input includes Microsoft's 57-byte copyright prefix.
    static func signature(at date: Date = Date()) -> String {
        let seconds = Int64(date.timeIntervalSince1970) + 11_644_473_600
        let ticks = (seconds - seconds % 300) * 10_000_000
        let message = Data((copyright + String(ticks) + token).utf8)
        let digest = Data(SHA256.hash(data: message))
        let checksum = cs64(message: message, digest: digest)
        return (checksum + digest).map { String(format: "%02X", $0) }.joined()
            .replacingOccurrences(of: "", with: "") // formatted below with checksum delimiter
    }

    static func signatureV2(at date: Date = Date()) -> String {
        let seconds = Int64(date.timeIntervalSince1970) + 11_644_473_600
        let ticks = (seconds - seconds % 300) * 10_000_000
        let message = Data((copyright + String(ticks) + token).utf8)
        let digest = Data(SHA256.hash(data: message))
        let cs = cs64(message: message, digest: digest)
        let hex: (Data) -> String = { $0.map { String(format: "%02X", $0) }.joined() }
        return hex(cs) + "-" + hex(digest)
    }

    private static func rotate16(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }
    private static func littleWord(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
    private static func swap(_ word: UInt32, _ key: UInt32,
                             _ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        let sum = (word &* key) &+ (rotate16(word) &* a)
        let product = rotate16(sum) &* b
        return (rotate16(product) &* c) &+ product
    }
    private static func mix(_ value: UInt32, _ factors: [UInt32]) -> UInt32 {
        factors.reduce(value) { rotate16($0) &* $1 }
    }

    private static func cs64(message: Data, digest: Data) -> Data {
        let digestBytes = Array(digest)
        let firstKey = littleWord(digestBytes, 0) | 1
        let secondKey = littleWord(digestBytes, 4) | 1
        var bytes = Array(message)
        bytes += [UInt8](repeating: 0, count: (8 - bytes.count % 8) % 8)
        var sum: UInt32 = 0
        var last: UInt32 = 0
        var state: UInt32 = 0
        var stateSum: UInt32 = 0
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            let a = littleWord(bytes, offset)
            let b = littleWord(bytes, offset + 4)
            let first = swap(a, firstKey, 0xEF0569FB, 0x76F50F34, 0xC3EFEA97)
            last = swap(b, secondKey, 0xC31713DB, 0x1881CE3C, 0x35BD1EC9)
            sum = sum &+ first &+ last
            state = mix((state &+ a) &* firstKey,
                        [0xCF98B111, 0x87085B9F, 0x12CEB96D, 0x257E1D83])
            stateSum = stateSum &+ state
            state = mix((state &+ b) &* secondKey,
                        [0xA27416F5, 0xD38396FF, 0x7C932B89, 0xBFA49F69])
            stateSum = stateSum &+ state
        }
        var result = Data()
        for word in [last ^ state, sum ^ stateSum] {
            for shift in [0, 8, 16, 24] {
                result.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return result
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date()) + "Z"
    }

    /// A single, bounded paragraph. Callers split longer pages to stay under the
    /// service's undocumented message size limits.
    static func synthesize(_ text: String, voice: String, rate: Int = 0) async throws -> Data {
        var components = URLComponents(string:
            "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: token),
            URLQueryItem(name: "ConnectionId", value: requestID),
            URLQueryItem(name: "Sec-MS-GEC", value: signatureV2()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "2-" + chromium)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
                         forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
            forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    let config = #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
                    try await socket.send(.string(
                        "X-Timestamp:" + timestamp() +
                        "\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" + config))
                    let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(voice)'><prosody pitch='+0Hz' rate='\(rate >= 0 ? "+" : "")\(rate)%' volume='+0%'>\(escapeXML(text))</prosody></voice></speak>"
                    try await socket.send(.string(
                        "X-RequestId:\(requestID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:" +
                        timestamp() + "\r\nPath:ssml\r\n\r\n" + ssml))
                    var audio = Data()
                    while true {
                        try Task.checkCancellation()
                        let message = try await socket.receive()
                        switch message {
                        case .string(let value):
                            if value.contains("Path:turn.end") {
                                guard !audio.isEmpty else { throw Failure.emptyAudio }
                                return audio
                            }
                        case .data(let value):
                            guard value.count >= 2 else { continue }
                            let headerLength = (Int(value[value.startIndex]) << 8) |
                                               Int(value[value.index(after: value.startIndex)])
                            let headerEnd = 2 + headerLength
                            guard value.count >= headerEnd else { throw Failure.invalidFrame }
                            let header = String(data: value.subdata(in: 2..<headerEnd), encoding: .utf8) ?? ""
                            if header.contains("Path:audio") && value.count > headerEnd {
                                audio.append(value.subdata(in: headerEnd..<value.count))
                            }
                        @unknown default:
                            throw Failure.invalidFrame
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw Failure.timeout
                }
                defer {
                    group.cancelAll()
                    socket.cancel(with: .normalClosure, reason: nil)
                }
                return try await group.next()!
            }
        } onCancel: {
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }
}
