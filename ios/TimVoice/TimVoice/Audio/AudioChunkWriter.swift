import Foundation

/// Persists audio chunks to disk as a safety net.
/// If the app crashes or the pipeline falls behind, chunks are saved locally
/// and can be reprocessed on next launch.
final class AudioChunkWriter {
    private let storageDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageDir = docs.appendingPathComponent("audio_chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    /// Save a chunk to disk. Returns the file URL.
    func save(_ chunk: AudioChunk) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let filename = "chunk_\(formatter.string(from: chunk.startTime)).pcm"
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = storageDir.appendingPathComponent(filename)

        try? chunk.audioData.write(to: fileURL)

        // Also save metadata
        let meta = ChunkMetadata(
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            sampleRate: chunk.sampleRate,
            channels: chunk.channels,
            bitsPerSample: chunk.bitsPerSample,
            processed: false
        )
        let metaURL = fileURL.appendingPathExtension("json")
        if let metaData = try? JSONEncoder().encode(meta) {
            try? metaData.write(to: metaURL)
        }

        return fileURL
    }

    /// List all unprocessed chunk files.
    func unprocessedChunks() -> [(url: URL, metadata: ChunkMetadata)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { metaURL -> (URL, ChunkMetadata)? in
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(ChunkMetadata.self, from: data),
                      !meta.processed else { return nil }
                let pcmURL = metaURL.deletingPathExtension()
                return (pcmURL, meta)
            }
            .sorted { $0.1.startTime < $1.1.startTime }
    }

    /// Mark a chunk as processed (or delete it based on retention policy).
    func markProcessed(_ url: URL, delete: Bool = false) {
        let metaURL = url.appendingPathExtension("json")
        if delete {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: metaURL)
        } else {
            // Update metadata
            if var data = try? Data(contentsOf: metaURL),
               var meta = try? JSONDecoder().decode(ChunkMetadata.self, from: data) {
                meta.processed = true
                if let updated = try? JSONEncoder().encode(meta) {
                    try? updated.write(to: metaURL)
                }
            }
        }
    }

    /// Delete all chunks older than the given interval.
    func pruneOlderThan(_ interval: TimeInterval) {
        let cutoff = Date.now.addingTimeInterval(-interval)
        for (url, meta) in unprocessedChunks() {
            if meta.startTime < cutoff {
                markProcessed(url, delete: true)
            }
        }
    }
}

struct ChunkMetadata: Codable {
    let startTime: Date
    let endTime: Date
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    var processed: Bool
}
