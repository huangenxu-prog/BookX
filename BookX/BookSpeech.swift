import Foundation
import AVFoundation
import Combine

struct BookVoice: Identifiable, Hashable {
    let id: String
    let title: String

    /// Curated choices. A voice may be unavailable on the unofficial Edge service;
    /// BookSpeech falls back to the built-in iOS synthesizer in that case.
    static let choices: [BookVoice] = [
        .init(id: "zh-CN-XiaoxiaoNeural", title: "晓晓 · 温柔女声"),
        .init(id: "zh-CN-XiaoyiNeural", title: "晓伊 · 女声"),
        .init(id: "zh-CN-XiaochenNeural", title: "晓辰 · 女声"),
        .init(id: "zh-CN-YunxiNeural", title: "云希 · 男声"),
        .init(id: "zh-CN-YunyangNeural", title: "云扬 · 男声"),
        .init(id: "zh-CN-liaoning-XiaobeiNeural", title: "晓北 · 东北话"),
        .init(id: "zh-CN-shaanxi-XiaoniNeural", title: "晓妮 · 陕西话"),
        .init(id: "zh-HK-HiuMaanNeural", title: "晓曼 · 粤语")
    ]
}

/// Listening is additive: page rendering, EPUB caching, typography, and
/// reading position remain owned by ReaderView/BookLibrary.
@MainActor
final class BookSpeech: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var finishedPage: Int?
    @Published private(set) var engineName = "准备朗读"
    /// UTF-16 range in the unmodified text of the current reading page.
    @Published private(set) var activeRange: NSRange?
    @Published var systemOnly = UserDefaults.standard.bool(forKey: "BookX.speech.systemOnly") {
        didSet { UserDefaults.standard.set(systemOnly, forKey: "BookX.speech.systemOnly") }
    }
    @Published var voiceID: String = BookVoice.choices[0].id {
        didSet { UserDefaults.standard.set(voiceID, forKey: "BookX.speech.voice") }
    }
    @Published var speed: Double = 1.0 {
        didSet { UserDefaults.standard.set(speed, forKey: "BookX.speech.speed") }
    }

    private let systemVoice = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var activeUtterance: AVSpeechUtterance?
    private var networkTask: Task<Void, Never>?
    private var activePage: Int?
    private var generation = UUID()
    private struct SpeechPart {
        let text: String
        let range: NSRange
    }
    private var segments: [SpeechPart] = []
    private var segmentIndex = 0
    private var deferredSystemText: String?
    private var edgeRetryAfter: Date?

    override init() {
        super.init()
        systemVoice.delegate = self
        if let saved = UserDefaults.standard.string(forKey: "BookX.speech.voice"),
           BookVoice.choices.contains(where: { $0.id == saved }) {
            voiceID = saved
        }
        if UserDefaults.standard.object(forKey: "BookX.speech.speed") != nil {
            speed = min(1.3, max(0.8, UserDefaults.standard.double(forKey: "BookX.speech.speed")))
        }
    }

    func play(_ text: String, page: Int) {
        stopPlayback(deactivateSession: false)
        segments = Self.split(text, maximumUTF8Bytes: 640)
        guard !segments.isEmpty else {
            finishedPage = page
            return
        }
        activePage = page
        isSpeaking = true
        isPaused = false
        configureAudio()
        beginSegment()
    }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Even if playback category configuration fails, try speech.
        }
    }

    /// Build small sentence-aligned pieces, preserving every UTF-16 offset.
    /// Keeping the source text unchanged avoids drift between audio and page layout.
    private static func split(_ text: String, maximumUTF8Bytes: Int) -> [SpeechPart] {
        var result: [SpeechPart] = []
        var partial = ""
        var bytes = 0
        var utf16Location = 0
        var partStart = 0

        func appendPart() {
            guard !partial.isEmpty else { return }
            if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(SpeechPart(
                    text: partial,
                    range: NSRange(location: partStart, length: utf16Location - partStart)))
            }
            partial = ""
            bytes = 0
            partStart = utf16Location
        }

        for char in text {
            let piece = String(char)
            if bytes + piece.utf8.count > maximumUTF8Bytes && !partial.isEmpty {
                appendPart()
            }
            partial.append(char)
            bytes += piece.utf8.count
            utf16Location += piece.utf16.count
            if ("。！？；!?\n".contains(char) && partial.utf16.count >= 18) ||
                partial.utf16.count >= 180 {
                appendPart()
            }
        }
        appendPart()
        return result
    }

    private func beginSegment() {
        guard activePage != nil, segments.indices.contains(segmentIndex), !isPaused else { return }
        let text = segments[segmentIndex].text
        if systemOnly || (edgeRetryAfter != nil && edgeRetryAfter! > Date()) {
            startSystem(text)
            return
        }
        let thisGeneration = generation
        let chosenVoice = voiceID
        let chosenRate = Int((speed - 1) * 100)
        engineName = "正在连接在线语音"
        networkTask = Task { [weak self] in
            do {
                let result = try await EdgeSpeech.synthesize(text, voice: chosenVoice, rate: chosenRate)
                guard let self, self.generation == thisGeneration,
                      !Task.isCancelled else { return }
                self.networkTask = nil
                self.edgeRetryAfter = nil
                self.startOnline(result)
            } catch {
                guard let self, self.generation == thisGeneration,
                      !Task.isCancelled else { return }
                self.networkTask = nil
                // Do not retry a failing endpoint on every page of a long book.
                self.edgeRetryAfter = Date().addingTimeInterval(300)
                self.startSystem(text)
            }
        }
    }

    private func startOnline(_ data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            engineName = "Edge 自然语音"
            activeRange = segments[segmentIndex].range
            if !isPaused && !player.play() {
                audioPlayer = nil
                startSystem(segments[segmentIndex])
            }
        } catch {
            startSystem(segments[segmentIndex])
        }
    }

    private func startSystem(_ text: String) {
        engineName = "iPhone 系统语音"
        activeRange = segments.indices.contains(segmentIndex) ? segments[segmentIndex].range : nil
        if isPaused {
            deferredSystemText = text
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceID.hasPrefix("zh-HK") ? "zh-HK" : "zh-CN")
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate,
                                 AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        activeUtterance = utterance
        systemVoice.speak(utterance)
    }

    func togglePause() {
        guard isSpeaking else { return }
        if isPaused {
            isPaused = false
            if let player = audioPlayer { _ = player.play() }
            else if systemVoice.isPaused { _ = systemVoice.continueSpeaking() }
            else if let pending = deferredSystemText {
                deferredSystemText = nil
                startSystem(pending)
            } else if networkTask == nil { beginSegment() }
        } else {
            isPaused = true
            audioPlayer?.pause()
            if systemVoice.isSpeaking {
                _ = systemVoice.pauseSpeaking(at: .immediate)
            }
        }
    }

    func stop() { stopPlayback(deactivateSession: true) }

    private func stopPlayback(deactivateSession: Bool) {
        generation = UUID()
        networkTask?.cancel()
        networkTask = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeUtterance = nil
        systemVoice.stopSpeaking(at: .immediate)
        activePage = nil
        segments.removeAll()
        segmentIndex = 0
        deferredSystemText = nil
        isSpeaking = false
        isPaused = false
        finishedPage = nil
        activeRange = nil
        engineName = "准备朗读"
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func finishSegment() {
        guard let page = activePage else { return }
        audioPlayer = nil
        activeUtterance = nil
        activeRange = nil
        segmentIndex += 1
        if segments.indices.contains(segmentIndex) {
            if !isPaused { beginSegment() }
        } else {
            isSpeaking = false
            isPaused = false
            activePage = nil
            finishedPage = page
        }
    }

    /// Native speech supplies genuine word timing; online audio supplies a
    /// sentence-sized highlight instead of fabricated per-character timing.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.activeUtterance === utterance,
                  self.segments.indices.contains(self.segmentIndex) else { return }
            let part = self.segments[self.segmentIndex]
            guard characterRange.location >= 0, characterRange.length > 0,
                  NSMaxRange(characterRange) <= (part.text as NSString).length else { return }
            self.activeRange = NSRange(
                location: part.range.location + characterRange.location,
                length: characterRange.length)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.finishSegment()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.activeUtterance === utterance else { return }
            self.finishSegment()
        }
    }
}
