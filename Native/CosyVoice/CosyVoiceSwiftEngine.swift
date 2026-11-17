import Foundation

// Staging implementation: include in the BookX target only after the native
// static libraries and their link dependencies have passed the iOS CI gate.
// The C declarations correspond to Native/CosyVoice/BookXCosyVoiceBridge.h.
@_silgen_name("bookx_cosyvoice_open")
private func cosyOpen(_ directory: UnsafePointer<CChar>, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?
@_silgen_name("bookx_cosyvoice_synthesize")
private func cosySynthesize(_ engine: OpaquePointer, _ text: UnsafePointer<CChar>,
                            _ samples: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                            _ count: UnsafeMutablePointer<Int>,
                            _ rate: UnsafeMutablePointer<Int32>,
                            _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("bookx_cosyvoice_cancel")
private func cosyCancel(_ engine: OpaquePointer)
@_silgen_name("bookx_cosyvoice_close")
private func cosyClose(_ engine: OpaquePointer)
@_silgen_name("bookx_cosyvoice_free")
private func cosyFree(_ memory: UnsafeMutableRawPointer?)

/// Serializes model use. No engine initialization occurs until the first narration.
actor CosyVoiceSwiftEngine {
    private var handle: OpaquePointer?
    private var activeSession: UUID?
    private let modelDirectory: URL

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func synthesize(_ text: String, cancellation: SpeechCancellation) throws -> SpeechPCM {
        try Task.checkCancellation()
        try cancellation.check()
        activeSession = cancellation.id
        if handle == nil {
            var rawError: UnsafeMutablePointer<CChar>?
            handle = modelDirectory.path.withCString { cosyOpen($0, &rawError) }
            defer { if let rawError { cosyFree(UnsafeMutableRawPointer(rawError)) } }
            guard handle != nil else {
                throw failure(rawError.map { String(cString: $0) } ?? "CosyVoice 3 模型加载失败。")
            }
        }
        guard let handle else { throw failure("CosyVoice 3 引擎不可用。") }
        try cancellation.check()

        var rawSamples: UnsafeMutablePointer<Float>?
        var sampleCount = 0
        var sampleRate: Int32 = 0
        var rawError: UnsafeMutablePointer<CChar>?
        let status = text.withCString {
            cosySynthesize(handle, $0, &rawSamples, &sampleCount, &sampleRate, &rawError)
        }
        defer {
            if let rawSamples { cosyFree(UnsafeMutableRawPointer(rawSamples)) }
            if let rawError { cosyFree(UnsafeMutableRawPointer(rawError)) }
        }
        try cancellation.check()
        try Task.checkCancellation()
        guard status == 0, let rawSamples, sampleCount > 0, sampleRate > 0 else {
            throw failure(rawError.map { String(cString: $0) } ?? "CosyVoice 3 未生成有效声音。")
        }
        let samples = Array(UnsafeBufferPointer(start: rawSamples, count: sampleCount))
        guard samples.allSatisfy(\.isFinite) else {
            throw failure("CosyVoice 3 返回了无效音频数据。")
        }
        return SpeechPCM(samples: samples, sampleRate: Int(sampleRate))
    }

    /// Called after the current inference has returned. In-flight interruption
    /// needs a separately synchronized native cancellation owner.
    func release(session: UUID) {
        guard activeSession == session else { return }
        if let handle { cosyClose(handle) }
        handle = nil
        activeSession = nil
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BookX.CosyVoice3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
