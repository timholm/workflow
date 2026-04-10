import Foundation

/// Local persistence for transcription segments.
/// Stores Tim's transcribed words on-device in a simple JSON-lines file,
/// organized by date. This is the source of truth — server sync is secondary.
final class TranscriptionStore {
    static let shared = TranscriptionStore()

    private let storageDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageDir = docs.appendingPathComponent("transcriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Write

    func save(_ segment: TranscriptionSegment) {
        let dateStr = dateString(for: segment.timestamp)
        let fileURL = storageDir.appendingPathComponent("\(dateStr).jsonl")

        guard let line = try? encoder.encode(segment),
              var lineStr = String(data: line, encoding: .utf8) else { return }

        lineStr += "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(lineStr.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? lineStr.data(using: .utf8)?.write(to: fileURL)
        }
    }

    // MARK: - Read

    func segmentsForDate(_ date: Date) -> [TranscriptionSegment] {
        let dateStr = dateString(for: date)
        let fileURL = storageDir.appendingPathComponent("\(dateStr).jsonl")

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        return content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(TranscriptionSegment.self, from: Data(line.utf8))
            }
    }

    func segmentsForToday() -> [TranscriptionSegment] {
        segmentsForDate(.now)
    }

    /// All unsynced segments across all dates.
    func unsyncedSegments() -> [TranscriptionSegment] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { fileURL -> [TranscriptionSegment] in
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
                return content
                    .split(separator: "\n")
                    .compactMap { try? decoder.decode(TranscriptionSegment.self, from: Data($0.utf8)) }
                    .filter { !$0.synced }
            }
    }

    func unsyncedCount() -> Int {
        unsyncedSegments().count
    }

    /// Mark a segment as synced.
    func markSynced(id: String) {
        // Read all files and update the matching segment
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where fileURL.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n")

            var updated = false
            let newLines: [String] = lines.map { line in
                guard var segment = try? decoder.decode(TranscriptionSegment.self, from: Data(line.utf8)),
                      segment.id == id else {
                    return String(line)
                }
                segment.synced = true
                updated = true
                if let data = try? encoder.encode(segment), let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return String(line)
            }

            if updated {
                let newContent = newLines.joined(separator: "\n") + "\n"
                try? newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                return
            }
        }
    }

    // MARK: - Helpers

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
