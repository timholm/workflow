import Foundation
import Combine

/// The core pipeline that orchestrates the entire flow:
/// Audio chunk → Voice Activity Detection → Speaker Diarization → Tim Identification →
/// Transcription → Local Storage → Server Sync
///
/// Every 30 seconds, a new audio chunk arrives from AudioManager.
/// This pipeline processes it entirely on-device.
final class AudioPipeline: ObservableObject {
    static let shared = AudioPipeline()

    @Published var todaySegmentCount = 0
    @Published var todayWordCount = 0
    @Published var pendingSyncCount = 0
    @Published var uptimeString = "00:00:00"

    private let voiceProfile = VoiceProfileManager.shared
    private let speakerEncoder = SpeakerEncoder.shared
    private let transcriptionEngine = TranscriptionEngine.shared
    private let chunkWriter = AudioChunkWriter()
    private let store = TranscriptionStore.shared
    private let serverSync = ServerSync.shared

    private var startTime: Date?
    private var uptimeTimer: Timer?
    private let processingQueue = DispatchQueue(label: "com.timvoice.pipeline", qos: .userInitiated)

    /// Minimum RMS energy to consider a frame as containing speech
    private let vadEnergyThreshold: Float = 0.01

    /// Minimum segment duration (seconds) worth transcribing
    private let minSegmentDuration: TimeInterval = 1.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        startTime = .now
        startUptimeTimer()

        // Wire up to AudioManager
        AudioManager.shared.onChunkReady = { [weak self] chunk in
            self?.processChunk(chunk)
        }

        // Process any unprocessed chunks from previous sessions
        reprocessPendingChunks()

        print("[Pipeline] Started")
    }

    func stop() {
        AudioManager.shared.onChunkReady = nil
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        startTime = nil
        print("[Pipeline] Stopped")
    }

    // MARK: - Chunk Processing

    private func processChunk(_ chunk: AudioChunk) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // 1. Save chunk to disk as safety net
            let savedURL = self.chunkWriter.save(chunk)

            // 2. Voice Activity Detection — find segments with speech
            let speechSegments = self.detectSpeech(in: chunk)

            guard !speechSegments.isEmpty else {
                // No speech detected — discard
                self.chunkWriter.markProcessed(savedURL, delete: true)
                return
            }

            // 3. For each speech segment, check if it's Tim
            var timSegments: [Data] = []

            for segment in speechSegments {
                let embedding = self.speakerEncoder.extractEmbedding(
                    from: segment,
                    sampleRate: chunk.sampleRate
                )
                let similarity = self.voiceProfile.verifySpeaker(embedding: embedding)

                if similarity >= self.voiceProfile.verificationThreshold {
                    timSegments.append(segment)
                }
                // Non-Tim audio is simply not added — it's discarded
            }

            guard !timSegments.isEmpty else {
                self.chunkWriter.markProcessed(savedURL, delete: true)
                return
            }

            // 4. Transcribe only Tim's speech
            let combined = timSegments.reduce(Data()) { $0 + $1 }
            let results = self.transcriptionEngine.transcribeSync(
                pcmData: combined,
                sampleRate: chunk.sampleRate
            )

            guard !results.isEmpty else {
                self.chunkWriter.markProcessed(savedURL, delete: true)
                return
            }

            // 5. Store transcriptions locally
            let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !fullText.isEmpty else {
                self.chunkWriter.markProcessed(savedURL, delete: true)
                return
            }

            let segment = TranscriptionSegment(
                id: UUID().uuidString,
                text: fullText,
                timestamp: chunk.startTime,
                durationSeconds: chunk.endTime.timeIntervalSince(chunk.startTime),
                confidence: results.map(\.confidence).reduce(0, +) / Float(results.count)
            )

            self.store.save(segment)

            // 6. Update stats
            DispatchQueue.main.async {
                self.todaySegmentCount += 1
                self.todayWordCount += fullText.split(separator: " ").count
                self.pendingSyncCount = self.store.unsyncedCount()
            }

            // 7. Queue for server sync
            self.serverSync.queueForSync(segment)

            // 8. Delete raw audio — only the transcription persists
            self.chunkWriter.markProcessed(savedURL, delete: true)

            print("[Pipeline] Processed chunk: \(fullText.prefix(60))...")
        }
    }

    // MARK: - Voice Activity Detection

    /// Simple energy-based VAD: splits audio into speech/non-speech regions.
    /// Returns segments of audio data that likely contain speech.
    private func detectSpeech(in chunk: AudioChunk) -> [Data] {
        let bytesPerSample = chunk.bitsPerSample / 8
        let samplesPerFrame = chunk.sampleRate / 10  // 100ms frames
        let bytesPerFrame = samplesPerFrame * bytesPerSample
        let totalFrames = chunk.audioData.count / bytesPerFrame

        guard totalFrames > 0 else { return [] }

        var speechRanges: [(start: Int, end: Int)] = []
        var inSpeech = false
        var speechStart = 0
        var silenceFrames = 0
        let maxSilenceFrames = 5 // 500ms of silence ends a segment

        for frame in 0..<totalFrames {
            let offset = frame * bytesPerFrame
            let end = min(offset + bytesPerFrame, chunk.audioData.count)
            let frameData = chunk.audioData.subdata(in: offset..<end)

            let energy = computeRMS(frameData)

            if energy > vadEnergyThreshold {
                if !inSpeech {
                    inSpeech = true
                    speechStart = offset
                }
                silenceFrames = 0
            } else if inSpeech {
                silenceFrames += 1
                if silenceFrames >= maxSilenceFrames {
                    let speechEnd = (frame - maxSilenceFrames + 1) * bytesPerFrame
                    speechRanges.append((speechStart, speechEnd))
                    inSpeech = false
                    silenceFrames = 0
                }
            }
        }

        // Close any open speech segment
        if inSpeech {
            speechRanges.append((speechStart, chunk.audioData.count))
        }

        // Filter out segments shorter than minimum duration
        let minBytes = Int(minSegmentDuration) * chunk.sampleRate * bytesPerSample
        return speechRanges
            .filter { $0.end - $0.start >= minBytes }
            .map { range in
                chunk.audioData.subdata(in: range.start..<min(range.end, chunk.audioData.count))
            }
    }

    private func computeRMS(_ data: Data) -> Float {
        let samples = data.withUnsafeBytes { ptr -> [Int16] in
            let bound = ptr.bindMemory(to: Int16.self)
            return Array(bound)
        }
        guard !samples.isEmpty else { return 0 }

        let sumSquares = samples.reduce(Float(0)) { sum, sample in
            let f = Float(sample) / Float(Int16.max)
            return sum + f * f
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    // MARK: - Recovery

    private func reprocessPendingChunks() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            let pending = self.chunkWriter.unprocessedChunks()
            guard !pending.isEmpty else { return }

            print("[Pipeline] Reprocessing \(pending.count) chunks from previous session")

            for (url, meta) in pending {
                guard let audioData = try? Data(contentsOf: url) else { continue }
                let chunk = AudioChunk(
                    audioData: audioData,
                    startTime: meta.startTime,
                    endTime: meta.endTime,
                    sampleRate: meta.sampleRate,
                    channels: meta.channels,
                    bitsPerSample: meta.bitsPerSample
                )
                self.processChunk(chunk)
            }
        }
    }

    // MARK: - Uptime

    private func startUptimeTimer() {
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let start = self?.startTime else { return }
            let elapsed = Int(Date.now.timeIntervalSince(start))
            let h = elapsed / 3600
            let m = (elapsed % 3600) / 60
            let s = elapsed % 60
            self?.uptimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }
}
