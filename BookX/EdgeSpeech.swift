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

    /// v2 token: SHA256 of the 57-byte Microsoft copyright prefix plus
    /// the time-based salt, and the proprietary CS64 digest of the salt.
    /// The latter is NOT a regular SHA256, nor a digest of the prefix.
    static func signatureV2(at date: Date = Date()) -> String {
        let seconds = Int64(date.timeIntervalSince1970) + 11_644_473_600
        let ticks = (seconds - seconds % 300) * 10_000_000
        let salt = Data((String(ticks) + token).utf8)
        let digest = Data(SHA256.hash(data: Data(copyright.utf8) + salt))
        let checksum = cs64(salt: salt, digest: digest)
        func hex(_ bytes: Data) -> String {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        return hex(checksum) + "-" + hex(digest)
    }

    private static func rotate16(_ value: UInt32) -> UInt32 {
        (value << 16) | (value >> 16)
    }

    private static func littleWord(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func cs64(salt: Data, digest: Data) -> Data {
        let digestBytes = Array(digest)
        let keyA = littleWord(digestBytes, 0) | 1
        let keyB = littleWord(digestBytes, 4) | 1
        let factor: UInt32 = 0x82893933
        let factors: [UInt32] = [keyA &* factor, keyB &* factor]
        // The fourteen seed terms/offsets are part of the v2 CS64 algorithm.
        let constants: [(UInt32, UInt32)] = [
            (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D),
            (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF),
            (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
            (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB),
            (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464),
            (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
            (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167)
        ]
        var terms: [UInt32] = constants.enumerated().map {
            $0.element.0 &* factors[$0.offset % 2]
        }
        var offsets: [UInt32] = constants.map { $0.1 }
        var bytes: [UInt8] = [0] + Array(salt)
        while bytes.count % 4 != 0 { bytes.append(0) }
        var words: [UInt32] = []
        for i in stride(from: 0, to: bytes.count, by: 4) {
            words.append(littleWord(bytes, i))
        }
        if words.count % 2 != 0 { words.append(0) }
        for (index, word) in words.enumerated() {
            var term = word &* (index % 2 == 0 ? keyA : keyB)
            var offset = rotate16(word) &*
                (index % 2 == 0 ? UInt32(0xEF0569FB) : UInt32(0xC31713DB))
            if index == 0 {
                term = term &+ (0xF2F90B1A &* factors[0])
                offset = offset &+ 0x0B1A0000
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAcc: UInt32 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var acc: UInt32 = 0
        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index]
            let y = terms[index + 1]
            var t = rotate16(offsets[index] &+ x)
            var q = t &* 0x76F50F34
            swapAcc = swapAcc &+ ((rotate16(q) &* 0xC3EFEA97) &+ q)
            t = rotate16(offsets[index + 1] &+ y)
            q = t &* 0x1881CE3C
            swapLast = (rotate16(q) &* 0x35BD1EC9) &+ q
            swapAcc = swapAcc &+ swapLast

            state = state &* keyA &+ x
            state = rotate16(state) &* 0xCF98B111
            state = rotate16(state) &* 0x87085B9F
            state = rotate16(state) &* 0x12CEB96D
            state = rotate16(state) &* 0x257E1D83
            acc = acc &+ state
            t = state &* keyB &+ y
            t = rotate16(t) &* 0xA27416F5
            t = rotate16(t) &* 0xD38396FF
            state = rotate16((rotate16(t) &* 0x7C932B89)) &* 0xBFA49F69
            acc = acc &+ state
        }
        var output = Data()
        for word in [swapLast ^ state, swapAcc ^ acc] {
            for shift in [0, 8, 16, 24] {
                output.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return output
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
