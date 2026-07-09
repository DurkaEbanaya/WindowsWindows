import Foundation

/// Thread-safe structured diagnostics journal.
///
/// One JSON object per line at:
/// `~/Library/Application Support/WindowsWindows/diagnostics.jsonl`.
/// The format is deliberately append-only so a crash cannot corrupt older events.
public final class DiagnosticJournal: @unchecked Sendable {
    public static let shared = DiagnosticJournal()

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private var fileURL: URL?

    private struct Entry: Codable {
        let timestamp: String
        let category: String
        let event: String
        let fields: [String: String]
    }

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func configure(supportURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = supportURL.appendingPathComponent("diagnostics.jsonl")
    }

    public func log(_ category: String, _ event: String, fields: [String: CustomStringConvertible] = [:]) {
        let stringFields = fields.mapValues { String(describing: $0) }
        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            category: category,
            event: event,
            fields: stringFields
        )

        lock.lock()
        defer { lock.unlock() }
        guard let fileURL, let data = try? encoder.encode(entry) else { return }

        var line = data
        line.append(0x0A)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: [.atomic])
            }
        } catch {
            NSLog("DiagnosticJournal write failed: \(error.localizedDescription)")
        }
    }
}
