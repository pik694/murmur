import CryptoKit
import Foundation

/// Speech models, downloaded on demand from the official whisper.cpp Hugging Face repos
/// into ~/Library/Application Support/Murmur/Models and checked against a pinned SHA-256.
struct ModelSpec {
    let title: String
    let file: String
    let url: URL
    let sha256: String
    let bytes: Int64

    static let fast = ModelSpec(
        title: "Fast model (whisper small)", file: "ggml-small-q5_1.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", bytes: 190_085_487)

    static let accurate = ModelSpec(
        title: "Accurate model (whisper large-v3-turbo)", file: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", bytes: 574_041_195)

    static let vad = ModelSpec(
        title: "Silence detection (Silero VAD)", file: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf", bytes: 885_098)

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/Models", isDirectory: true)
    }

    var path: URL { Self.directory.appendingPathComponent(file) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: path.path) }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum DownloadError: LocalizedError {
    case badStatus(Int), checksum
    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Download failed (HTTP \(code))."
        case .checksum: return "Downloaded file is corrupted (checksum mismatch)."
        }
    }
}

/// One download at a time per model; progress and completion are reported on the main queue.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var jobs: [Int: (spec: ModelSpec, progress: (Double) -> Void, done: (Error?) -> Void)] = [:]
    private(set) var active: Set<String> = []

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func isDownloading(_ spec: ModelSpec) -> Bool { active.contains(spec.file) }

    func download(_ spec: ModelSpec, progress: @escaping (Double) -> Void, done: @escaping (Error?) -> Void) {
        guard !spec.isInstalled, !active.contains(spec.file) else { return }
        active.insert(spec.file)
        let task = session.downloadTask(with: spec.url)
        jobs[task.taskIdentifier] = (spec, progress, done)
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = jobs[downloadTask.taskIdentifier] else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : job.spec.bytes
        job.progress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = jobs[downloadTask.taskIdentifier] else { return }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw DownloadError.badStatus(http.statusCode)
            }
            guard try Self.sha256(of: location) == job.spec.sha256 else { throw DownloadError.checksum }
            try FileManager.default.createDirectory(at: ModelSpec.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: job.spec.path)
            try FileManager.default.moveItem(at: location, to: job.spec.path)
            finish(downloadTask.taskIdentifier, nil)
        } catch {
            finish(downloadTask.taskIdentifier, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task.taskIdentifier, error) }
    }

    private func finish(_ id: Int, _ error: Error?) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        active.remove(job.spec.file)
        job.done(error)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
