import Foundation
import AVFoundation

/// One playing segment and at most one prepared segment; no whole-book audio cache.
@MainActor
final class BookSpeech: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var finishedPage: Int?
    @Published var errorMessage: String?
    private let engine = KokoroVoiceEngine()
    private var cancellation = SpeechCancellation()
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var prepared: Data?
    private var segments: [String] = []
    private var nextSegment = 0
    private var activePage: Int?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
    }
    deinit {
        cancellation.cancel()
        worker?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func play(_ text: String, page: Int) {
        reset(releaseModel: false)
        segments = SpeechText.segments(text)
        guard !segments.isEmpty else { finishedPage = page; return }
        activePage = page
        errorMessage = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            isSpeaking = true
            prepareNext()
        } catch { fail(error) }
    }

    func togglePause() {
        guard activePage != nil else { return }
        if isPaused {
            do { try AVAudioSession.sharedInstance().setActive(true) }
            catch { fail(error); return }
            isPaused = false
            if let player {
                if !player.play() { fail(playbackError()); return }
            } else { startPrepared() }
            prepareNext()
            finishIfNeeded()
        } else { pause() }
    }
    private func pause() {
        guard activePage != nil else { return }
        isPaused = true
        player?.pause()
        // Let one in-flight segment finish; do not generate more while paused.
    }
    func stop() {
        reset(releaseModel: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func reset(releaseModel: Bool) {
        let previous = cancellation.id
        cancellation.cancel()
        worker?.cancel(); worker = nil
        generation = UUID()
        player?.stop(); player = nil
        prepared = nil; segments = []; nextSegment = 0; activePage = nil
        finishedPage = nil; isSpeaking = false; isPaused = false
        cancellation = SpeechCancellation()
        if releaseModel { Task { await engine.release(session: previous) } }
    }
    private func prepareNext() {
        guard activePage != nil, !isPaused, worker == nil, prepared == nil, nextSegment < segments.count else { return }
        let text = segments[nextSegment]
        nextSegment += 1
        let request = generation
        let token = cancellation
        let voiceEngine = engine
        worker = Task { [weak self] in
            do {
                let pcm = try await voiceEngine.synthesize(text, cancellation: token)
                let data = try await readerWorker(priority: .utility) { pcm.wav() }
                guard !Task.isCancelled, let self, request == self.generation else { return }
                self.worker = nil
                self.prepared = data
                self.startPrepared()
            } catch {
                guard !Task.isCancelled, let self, request == self.generation else { return }
                self.worker = nil
                self.fail(error)
            }
        }
    }
    private func startPrepared() {
        guard player == nil, !isPaused, let data = prepared else { return }
        prepared = nil
        do {
            let next = try AVAudioPlayer(data: data)
            next.delegate = self
            player = next
            guard next.play() else { throw playbackError() }
            prepareNext()
        } catch { fail(error) }
    }
    private func finishIfNeeded() {
        guard !isPaused, player == nil, prepared == nil, worker == nil,
              nextSegment == segments.count, let page = activePage else { return }
        activePage = nil
        isSpeaking = false
        finishedPage = page
    }
    private func fail(_ error: Error) {
        stop()
        errorMessage = error.localizedDescription
    }
    private func playbackError() -> NSError {
        NSError(domain: "BookX.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频播放失败，请重新启动听书。"])
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player, let page = self.activePage else { return }
            self.player = nil
            guard flag else { self.fail(self.playbackError()); return }
            if self.prepared != nil { self.startPrepared() }
            else { self.prepareNext(); self.finishIfNeeded() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.fail(error ?? self.playbackError())
        }
    }
}
