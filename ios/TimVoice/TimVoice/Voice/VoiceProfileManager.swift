import AVFoundation
import Accelerate
import Combine

/// Manages Tim's voice enrollment and stores his voiceprint (speaker embedding).
///
/// During enrollment, the user reads 5 prompts. Each sample is processed to extract
/// a speaker embedding vector. The final voiceprint is the averaged embedding across
/// all samples, giving a robust representation of Tim's voice.
final class VoiceProfileManager: ObservableObject {
    static let shared = VoiceProfileManager()

    @Published var isEnrolled = false
    @Published var enrollmentProgress: Double = 0.0

    /// Tim's voiceprint — a 192-dimensional speaker embedding vector
    private(set) var voiceprint: [Float]?

    private var enrollmentSamples: [[Float]] = []
    private var currentRecorder: AVAudioRecorder?
    private var sampleURLs: [URL] = []

    private let embeddingDimension = 192
    private let profileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        profileURL = docs.appendingPathComponent("tim_voiceprint.bin")
        loadProfile()
    }

    // MARK: - Enrollment

    func startEnrollmentSample(step: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrollment_\(step).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            currentRecorder = try AVAudioRecorder(url: url, settings: settings)
            currentRecorder?.record()
            if step < sampleURLs.count {
                sampleURLs[step] = url
            } else {
                sampleURLs.append(url)
            }
        } catch {
            print("[VoiceProfile] Failed to start enrollment recording: \(error)")
        }
    }

    func finishEnrollmentSample(step: Int) {
        currentRecorder?.stop()
        currentRecorder = nil

        guard step < sampleURLs.count else { return }
        let url = sampleURLs[step]

        // Extract embedding from this sample
        if let audioData = try? Data(contentsOf: url) {
            let embedding = SpeakerEncoder.shared.extractEmbedding(from: audioData, sampleRate: 16000)
            if step < enrollmentSamples.count {
                enrollmentSamples[step] = embedding
            } else {
                enrollmentSamples.append(embedding)
            }
        }

        enrollmentProgress = Double(enrollmentSamples.count) / 5.0
    }

    func finalizeEnrollment() {
        guard enrollmentSamples.count >= 3 else {
            print("[VoiceProfile] Need at least 3 samples for enrollment")
            return
        }

        // Average all enrollment embeddings to create a robust voiceprint
        voiceprint = averageEmbeddings(enrollmentSamples)
        saveProfile()

        // Cleanup temp files
        for url in sampleURLs {
            try? FileManager.default.removeItem(at: url)
        }
        sampleURLs = []
        enrollmentSamples = []

        isEnrolled = true
        print("[VoiceProfile] Enrollment complete. Voiceprint saved.")
    }

    // MARK: - Verification

    /// Compare an audio segment's embedding against Tim's voiceprint.
    /// Returns a similarity score between 0 and 1.
    /// Scores above 0.75 are considered a match.
    func verifySpeaker(embedding: [Float]) -> Float {
        guard let voiceprint = voiceprint else { return 0.0 }
        return cosineSimilarity(voiceprint, embedding)
    }

    /// Threshold for "this is Tim" vs "this is not Tim"
    var verificationThreshold: Float { 0.75 }

    // MARK: - Persistence

    private func saveProfile() {
        guard let voiceprint = voiceprint else { return }
        let data = voiceprint.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
        try? data.write(to: profileURL)
    }

    private func loadProfile() {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return }
        guard let data = try? Data(contentsOf: profileURL) else { return }

        let count = data.count / MemoryLayout<Float>.size
        guard count == embeddingDimension else { return }

        voiceprint = data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
        isEnrolled = true
        print("[VoiceProfile] Loaded existing voiceprint")
    }

    // MARK: - Math

    private func averageEmbeddings(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var result = [Float](repeating: 0, count: first.count)

        for embedding in embeddings {
            for i in 0..<min(result.count, embedding.count) {
                result[i] += embedding[i]
            }
        }

        let scale = 1.0 / Float(embeddings.count)
        for i in 0..<result.count {
            result[i] *= scale
        }

        // L2 normalize
        let norm = sqrt(result.map { $0 * $0 }.reduce(0, +))
        if norm > 0 {
            for i in 0..<result.count {
                result[i] /= norm
            }
        }

        return result
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
