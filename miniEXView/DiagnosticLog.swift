import Foundation

/// Synchronous append keeps the last received TCP chunk available after a crash.
final class DiagnosticLog {
    let url: URL
    private let lock = NSLock()
    private let handle: FileHandle?

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("miniEX-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "session-\(Self.fileDate.string(from: Date())).log"
        url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("START miniEX mExView \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))", flush: true)
    }

    func write(_ message: String, flush: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let stamp = Self.lineDate.string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        handle?.write(data)
        if flush { handle?.synchronizeFile() }
    }

    func rawTCP(_ data: Data) {
        write("RAW RX \(data.count) B: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))", flush: true)
    }

    private static let lineDate: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return formatter
    }()
    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; return formatter
    }()
}
