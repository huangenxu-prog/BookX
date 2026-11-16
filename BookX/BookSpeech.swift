import Foundation
import AVFoundation

/// Offline speech using the voices installed on the user's iPhone.
@MainActor
final class BookSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var finishedPage: Int?
    @Published var rate: Float = 0.50
    private let synthesizer = AVSpeechSynthesizer()
    private var activePage: Int?
    private var activeUtterance: AVSpeechUtterance?
    private var stopped = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(_ text: String, page: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopped = true
        synthesizer.stopSpeaking(at: .immediate)
        stopped = false
        finishedPage = nil
        activePage = page
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Foreground reading can still work when audio session configuration fails.
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = rate
        activeUtterance = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    func togglePause() {
        if isPaused {
            if synthesizer.continueSpeaking() { isPaused = false }
        } else if synthesizer.pauseSpeaking(at: .word) {
            isPaused = true
        }
    }

    func stop() {
        stopped = true
        activePage = nil
        activeUtterance = nil
        finishedPage = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.stopped, self.activeUtterance === utterance, let page = self.activePage else { return }
            self.isSpeaking = false
            self.isPaused = false
            self.activePage = nil
            self.activeUtterance = nil
            self.finishedPage = page
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.activeUtterance === utterance {
                self.activeUtterance = nil
                self.activePage = nil
                self.isSpeaking = false
                self.isPaused = false
            }
        }
    }
}
