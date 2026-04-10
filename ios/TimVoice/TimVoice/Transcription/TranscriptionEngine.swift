import Speech
import Foundation

/// On-device speech-to-text using Apple's Speech framework.
///
/// Uses SFSpeechRecognizer which runs entirely on-device (no network needed)
/// on iOS 17+. Falls back to server-based recognition on older iOS.
final class TranscriptionEngine {
    static let shared = TranscriptionEngine()

    private let speechRecognizer: SFSpeechRecognizer?
    private var isAuthorized = false

    private init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        requestAuthorization()
    }

    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            self?.isAuthorized = (status == .authorized)
            if status != .authorized {
                print("[Transcription] Speech recognition not authorized: \(status)")
            }
        }
    }

    /// Transcribe raw 16-bit PCM audio data.
    /// Returns transcribed text segments with timestamps.
    func transcribe(
        pcmData: Data,
        sampleRate: Int,
        completion: @escaping (Result<[TranscriptionResult], Error>) -> Void
    ) {
        guard isAuthorized, let recognizer = speechRecognizer, recognizer.isAvailable else {
            completion(.failure(TranscriptionError.notAvailable))
            return
        }

        // Write PCM data to a temporary WAV file (Speech framework needs a file URL)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe_\(UUID().uuidString).wav")

        do {
            let wavData = pcmToWAV(pcmData: pcmData, sampleRate: sampleRate)
            try wavData.write(to: tempURL)
        } catch {
            completion(.failure(error))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.requiresOnDeviceRecognition = true // force on-device, no cloud
        request.shouldReportPartialResults = false

        recognizer.recognitionTask(with: request) { result, error in
            // Cleanup temp file
            try? FileManager.default.removeItem(at: tempURL)

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let result = result, result.isFinal else {
                completion(.success([]))
                return
            }

            let segments = result.bestTranscription.segments.map { segment in
                TranscriptionResult(
                    text: segment.substring,
                    timestamp: segment.timestamp,
                    duration: segment.duration,
                    confidence: segment.confidence
                )
            }

            completion(.success(segments))
        }
    }

    /// Synchronous wrapper for use in the pipeline.
    func transcribeSync(pcmData: Data, sampleRate: Int) -> [TranscriptionResult] {
        let semaphore = DispatchSemaphore(value: 0)
        var results: [TranscriptionResult] = []

        transcribe(pcmData: pcmData, sampleRate: sampleRate) { result in
            if case .success(let segments) = result {
                results = segments
            }
            semaphore.signal()
        }

        semaphore.wait()
        return results
    }

    // MARK: - WAV Conversion

    private func pcmToWAV(pcmData: Data, sampleRate: Int) -> Data {
        let dataSize = pcmData.count
        let fileSize = 44 + dataSize

        var wav = Data()

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wav.append(pcmData)

        return wav
    }
}

struct TranscriptionResult {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Float
}

enum TranscriptionError: Error {
    case notAvailable
    case notAuthorized
}
