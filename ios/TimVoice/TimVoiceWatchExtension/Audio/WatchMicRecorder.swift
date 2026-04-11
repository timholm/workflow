import AVFoundation
import WatchKit
import Combine

/// Records audio from the Watch microphone when the iPhone is not reachable.
///
/// The Watch is the safety net: when Tim walks away from his phone (the goal),
/// his words still get captured. Every 30-second chunk is stored locally and
/// queued for transfer to the iPhone the moment it comes back in range.
///
/// Audio format matches the iPhone pipeline exactly: 16kHz mono 16-bit PCM.
final class WatchMicRecorder: NSObject, ObservableObject {
    static let shared = WatchMicRecorder()

    // MARK: - Published State

    @Published var isRecording = false

    // MARK: - Configuration

    /// Duration of each audio chunk in seconds.
    private let chunkDuration: TimeInterval = 30.0

    /// Target sample rate matching the iPhone pipeline.
    private let targetSampleRate: Double = 16000.0

    /// Maximum local buffer size before oldest chunks are pruned (50 MB).
    private let maxBufferBytes: UInt64 = 50 * 1024 * 1024

    // MARK: - Internal

    private let audioEngine = AVAudioEngine()
    private var chunkBuffer = Data()
    private var chunkStartTime: Date = .now
    private let storageDir: URL
    private let fileManager = FileManager.default

    // MARK: - Init

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageDir = docs.appendingPathComponent("watch_audio_chunks", isDirectory: true)
        super.init()
        try? fileManager.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setPreferredIOBufferDuration(0.02) // 20ms buffers
        try session.setActive(true)
    }

    // MARK: - Recording Control

    /// Begin recording from the Watch microphone.
    /// Called when WatchSessionManager detects the iPhone is unreachable.
    func startRecording() {
        guard !isRecording else { return }

        do {
            try configureAudioSession()
        } catch {
            print("[WatchMicRecorder] Failed to configure audio session: \(error)")
            return
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap using the hardware's native format. We convert to
        // 16kHz mono 16-bit PCM in processBuffer if the hardware differs.
        let tapFormat: AVAudioFormat
        if hardwareFormat.sampleRate == targetSampleRate && hardwareFormat.channelCount == 1 {
            tapFormat = hardwareFormat
        } else {
            // Use the hardware format for the tap — conversion happens in processBuffer.
            tapFormat = hardwareFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, inputFormat: tapFormat)
        }

        do {
            try audioEngine.start()
            isRecording = true
            chunkStartTime = .now
            chunkBuffer = Data()
            print("[WatchMicRecorder] Recording started")
        } catch {
            print("[WatchMicRecorder] Failed to start engine: \(error)")
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Stop recording and flush the remaining buffer.
    /// Called when the iPhone becomes reachable again.
    func stopRecording() {
        guard isRecording else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        // Flush remaining audio as a final chunk
        if !chunkBuffer.isEmpty {
            finalizeChunk()
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Transfer all pending chunks to the iPhone
        transferAllPendingChunks()

        print("[WatchMicRecorder] Recording stopped")
    }

    // MARK: - Buffer Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(inputFormat.channelCount)
        let inputSampleRate = inputFormat.sampleRate

        // Mix to mono if needed
        var monoSamples: [Float]
        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        } else {
            monoSamples = [Float](repeating: 0, count: frames)
            for ch in 0..<channelCount {
                let chPtr = channelData[ch]
                for i in 0..<frames {
                    monoSamples[i] += chPtr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frames {
                monoSamples[i] *= scale
            }
        }

        // Resample to 16kHz if the hardware rate differs
        let finalSamples: [Float]
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
            finalSamples = resample(monoSamples, from: inputSampleRate, to: targetSampleRate)
        } else {
            finalSamples = monoSamples
        }

        // Convert float samples to 16-bit PCM
        let pcmData = finalSamples.withUnsafeBufferPointer { ptr -> Data in
            var data = Data(capacity: ptr.count * 2)
            for sample in ptr {
                let clamped = max(-1.0, min(1.0, sample))
                let int16 = Int16(clamped * Float(Int16.max))
                withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        chunkBuffer.append(pcmData)

        // Finalize chunk when duration has elapsed
        if Date.now.timeIntervalSince(chunkStartTime) >= chunkDuration {
            finalizeChunk()
        }
    }

    /// Simple linear interpolation resampler.
    /// Good enough for voice at nearby rates (e.g., 44.1kHz -> 16kHz).
    private func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        let ratio = inputRate / outputRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let srcFloor = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcFloor))

            if srcFloor + 1 < samples.count {
                output[i] = samples[srcFloor] * (1.0 - frac) + samples[srcFloor + 1] * frac
            } else if srcFloor < samples.count {
                output[i] = samples[srcFloor]
            }
        }
        return output
    }

    // MARK: - Chunk Management

    private func finalizeChunk() {
        guard !chunkBuffer.isEmpty else { return }

        let now = Date.now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: chunkStartTime).replacingOccurrences(of: ":", with: "-")
        let filename = "watch_chunk_\(timestamp).pcm"
        let fileURL = storageDir.appendingPathComponent(filename)

        do {
            try chunkBuffer.write(to: fileURL)
        } catch {
            print("[WatchMicRecorder] Failed to write chunk: \(error)")
        }

        // Save metadata alongside the PCM file
        let metadata = WatchChunkMetadata(
            startTime: chunkStartTime,
            endTime: now,
            sampleRate: Int(targetSampleRate),
            channels: 1,
            bitsPerSample: 16,
            transferred: false
        )
        let metaURL = fileURL.appendingPathExtension("json")
        if let metaData = try? JSONEncoder().encode(metadata) {
            try? metaData.write(to: metaURL)
        }

        // Reset for the next chunk
        chunkBuffer = Data()
        chunkStartTime = .now

        // Enforce the 50MB buffer limit
        pruneIfOverLimit()

        // If the phone is reachable now, transfer immediately
        if !WatchSessionManager.shared.isPhoneFarAway {
            transferFile(at: fileURL, metadata: metadata)
        }
    }

    // MARK: - Transfer

    /// Queue all untransferred chunks for transfer to the iPhone.
    func transferAllPendingChunks() {
        let pendingChunks = listPendingChunks()
        for (fileURL, metadata) in pendingChunks {
            transferFile(at: fileURL, metadata: metadata)
        }
    }

    private func transferFile(at url: URL, metadata: WatchChunkMetadata) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let transferMeta: [String: Any] = [
            "source": "watch_mic",
            "startTime": metadata.startTime.timeIntervalSince1970,
            "endTime": metadata.endTime.timeIntervalSince1970,
            "sampleRate": metadata.sampleRate,
            "channels": metadata.channels,
            "bitsPerSample": metadata.bitsPerSample
        ]

        WatchSessionManager.shared.sendAudioFile(at: url, metadata: transferMeta)

        // Mark as transferred so we don't send it again
        markTransferred(url)
    }

    // MARK: - Local Storage Management

    /// Returns all chunks that haven't been transferred yet, sorted oldest first.
    private func listPendingChunks() -> [(url: URL, metadata: WatchChunkMetadata)] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { metaURL -> (URL, WatchChunkMetadata)? in
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(WatchChunkMetadata.self, from: data),
                      !meta.transferred else { return nil }
                let pcmURL = metaURL.deletingPathExtension() // strip .json to get .pcm
                guard fileManager.fileExists(atPath: pcmURL.path) else { return nil }
                return (pcmURL, meta)
            }
            .sorted { $0.1.startTime < $1.1.startTime }
    }

    private func markTransferred(_ pcmURL: URL) {
        let metaURL = pcmURL.appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? JSONDecoder().decode(WatchChunkMetadata.self, from: data) else { return }
        meta.transferred = true
        if let updated = try? JSONEncoder().encode(meta) {
            try? updated.write(to: metaURL)
        }
    }

    /// Prune oldest chunks when the total buffer exceeds 50MB.
    private func pruneIfOverLimit() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        let pcmFiles = files.filter { $0.pathExtension == "pcm" }

        // Calculate total size
        var totalSize: UInt64 = 0
        var fileSizes: [(url: URL, size: UInt64, date: Date)] = []

        for file in pcmFiles {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? UInt64 else { continue }
            let created = (attrs[.creationDate] as? Date) ?? .distantPast
            totalSize += size
            fileSizes.append((url: file, size: size, date: created))
        }

        guard totalSize > maxBufferBytes else { return }

        // Sort oldest first, prune until under limit
        let sorted = fileSizes.sorted { $0.date < $1.date }
        var currentSize = totalSize

        for entry in sorted {
            guard currentSize > maxBufferBytes else { break }
            // Delete the PCM file and its metadata
            try? fileManager.removeItem(at: entry.url)
            try? fileManager.removeItem(at: entry.url.appendingPathExtension("json"))
            currentSize -= entry.size
            print("[WatchMicRecorder] Pruned \(entry.url.lastPathComponent) — \(entry.size) bytes freed")
        }
    }

    /// Delete all transferred chunks to reclaim space.
    /// Called periodically or after confirming iPhone received the files.
    func cleanupTransferredChunks() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for metaURL in files where metaURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(WatchChunkMetadata.self, from: data),
                  meta.transferred else { continue }

            let pcmURL = metaURL.deletingPathExtension()
            try? fileManager.removeItem(at: pcmURL)
            try? fileManager.removeItem(at: metaURL)
        }
    }
}

// MARK: - Metadata

struct WatchChunkMetadata: Codable {
    let startTime: Date
    let endTime: Date
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    var transferred: Bool
}
