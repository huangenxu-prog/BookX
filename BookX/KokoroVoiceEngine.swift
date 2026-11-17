import Foundation
import SherpaOnnx

/// The actor serializes the native model's lifetime and all inference. No model
/// allocation or filesystem work happens when the reader or bookshelf opens.
actor KokoroVoiceEngine {
    private var model: SherpaOnnxOfflineTtsWrapper?
    private var activeSession: UUID?
    private let resources: URL?
    init(resources: URL? = nil) { self.resources = resources }
    var isLoaded: Bool { model != nil }

    func synthesize(_ text: String, cancellation: SpeechCancellation) throws -> SpeechPCM {
        try Task.checkCancellation()
        try cancellation.check()
        activeSession = cancellation.id
        if model == nil { model = try loadModel() }
        try cancellation.check()
        guard let model else { throw failure("语音模型未能加载。") }
        // C retains neither the callback context nor the supplied text beyond this call.
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        let audio = model.generateWithCallbackWithArg(text: text, callback: { _, _, raw in
            guard let raw else { return 0 }
            return Unmanaged<SpeechCancellation>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 0 : 1
        }, arg: context, sid: 3, speed: 1.0) // Upstream voice zf_001, Mandarin female.
        try cancellation.check()
        try Task.checkCancellation()
        let samples = audio.samples
        guard audio.sampleRate > 0, !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw failure("本段文字未生成有效声音，请重新启动听书。")
        }
        return SpeechPCM(samples: samples, sampleRate: Int(audio.sampleRate))
    }

    func release(session: UUID) {
        // A delayed stop from the previous page must never unload a newer session.
        guard activeSession == session else { return }
        model = nil
        activeSession = nil
    }

    private func loadModel() throws -> SherpaOnnxOfflineTtsWrapper {
        guard let root = resources ?? Bundle.main.resourceURL?.appendingPathComponent("Kokoro") else {
            throw failure("安装包缺少离线语音模型。")
        }
        func path(_ name: String) throws -> String {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw failure("安装包缺少离线语音资源：\(name)")
            }
            return url.path
        }
        let kokoro = try sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.int8.onnx"), voices: path("voices.bin"),
            tokens: path("tokens.txt"), dictDir: path("dict"),
            lexicon: path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt"), lang: "zh")
        let configuration = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2, debug: 0, provider: "cpu")
        let rules = try ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(path).joined(separator: ",")
        var tts = sherpaOnnxOfflineTtsConfig(model: configuration, ruleFsts: rules, maxNumSentences: 1)
        let result = SherpaOnnxOfflineTtsWrapper(config: &tts)
        guard result.tts != nil else { throw failure("离线语音引擎初始化失败。") }
        return result
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "BookX.Kokoro", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
