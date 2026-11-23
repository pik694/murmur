import Foundation
import whisper

/// A loaded whisper.cpp model. `transcribe` blocks, so call it off the main thread;
/// calls on one model are serialised (a whisper context is not re-entrant).
final class WhisperModel {
    private let ctx: OpaquePointer
    private let queue: DispatchQueue

    init?(path: String) {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, params) else { return nil }
        self.ctx = ctx
        self.queue = DispatchQueue(label: "murmur.whisper.\(URL(fileURLWithPath: path).lastPathComponent)")
    }

    deinit { whisper_free(ctx) }

    static func silenceLogs() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    func transcribe(_ samples: [Float], vadModel: String?) -> String {
        guard samples.count >= 8_000 else { return "" } // < 0.5 s
        return queue.sync {
            var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            p.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            p.no_timestamps = true
            p.no_context = true
            p.suppress_blank = true
            p.print_progress = false
            p.print_realtime = false
            p.print_timestamps = false
            p.print_special = false

            let language = strdup("auto")
            defer { free(language) }
            p.language = UnsafePointer(language)

            // Silero VAD drops silence, which otherwise makes whisper invent text ("Thank you.").
            var vadPath: UnsafeMutablePointer<CChar>?
            if let vadModel {
                vadPath = strdup(vadModel)
                p.vad = true
                p.vad_model_path = UnsafePointer(vadPath)
            }
            defer { free(vadPath) }

            let rc = samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
            guard rc == 0 else { return "" }
            var text = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let segment = whisper_full_get_segment_text(ctx, i) { text += String(cString: segment) }
            }
            return Self.clean(text)
        }
    }

    /// Drops markers like "[BLANK_AUDIO]" and normalises whitespace.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
