import AVFoundation
import Combine

/// Manages continuous 24/7 audio recording.
/// Uses AVAudioEngine for real-time audio capture and a background audio session
/// to prevent iOS from suspending the app.
final class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()

    @Published var isRecording = false
    @Published var currentAmplitude: Float = 0.0

    private let audioEngine = AVAudioEngine()
    private var chunkWriter: AudioChunkWriter?

    /// How long each audio chunk is before being handed to the pipeline (seconds)
    private let chunkDuration: TimeInterval = 30.0
    private var chunkStartTime: Date = .now
    private var chunkBuffer = Data()

    /// Callback: fires every time a chunk is ready for processing
    var onChunkReady: ((AudioChunk) -> Void)?

    private override init() {
        super.init()
        configureAudioSession()
        setupInterruptionHandling()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord + .defaultToSpeaker keeps the app alive in background
            // by declaring both playback and recording capabilities
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setPreferredSampleRate(16000) // 16kHz is ideal for speech
            try session.setPreferredIOBufferDuration(0.02) // 20ms buffers
            try session.setActive(true)
        } catch {
            print("[AudioManager] Failed to configure audio session: \(error)")
        }
    }

    /// Re-activate after system interruptions (phone calls, Siri, etc.)
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .ended {
                // Resume recording after interruption
                try? AVAudioSession.sharedInstance().setActive(true)
                if self?.isRecording == true {
                    self?.restartEngine()
                }
            }
        }
    }

    // MARK: - Recording Control

    func startRecording() {
        guard !isRecording else { return }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap to capture audio buffers in real time
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
            self?.processBuffer(buffer, time: time)
        }

        do {
            try audioEngine.start()
            isRecording = true
            chunkStartTime = .now
            chunkBuffer = Data()
            startSilentPlayback() // keeps app alive in background
            print("[AudioManager] Recording started")
        } catch {
            print("[AudioManager] Failed to start engine: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        stopSilentPlayback()
        isRecording = false

        // Flush remaining buffer as final chunk
        if !chunkBuffer.isEmpty {
            emitChunk()
        }

        print("[AudioManager] Recording stopped")
    }

    private func restartEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRecording = false
            self?.startRecording()
        }
    }

    // MARK: - Buffer Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        // Update amplitude for UI
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(frames))
        DispatchQueue.main.async { [weak self] in
            self?.currentAmplitude = rms
        }

        // Convert float samples to 16-bit PCM data for storage/processing
        let pcmData = samples.withUnsafeBufferPointer { ptr -> Data in
            Data(ptr.lazy.map { sample -> [UInt8] in
                let clamped = max(-1.0, min(1.0, sample))
                let int16 = Int16(clamped * Float(Int16.max))
                return [UInt8(int16 & 0xFF), UInt8((int16 >> 8) & 0xFF)]
            }.joined())
        }

        chunkBuffer.append(pcmData)

        // Check if chunk duration has elapsed
        if Date.now.timeIntervalSince(chunkStartTime) >= chunkDuration {
            emitChunk()
        }
    }

    private func emitChunk() {
        let chunk = AudioChunk(
            audioData: chunkBuffer,
            startTime: chunkStartTime,
            endTime: .now,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        chunkBuffer = Data()
        chunkStartTime = .now

        // Hand off to pipeline on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onChunkReady?(chunk)
        }
    }

    // MARK: - Silent Playback (Background Keep-Alive)

    private var silentPlayer: AVAudioPlayer?

    /// Plays a silent audio loop to keep the app active in background.
    /// iOS allows apps with active audio playback to run indefinitely.
    private func startSilentPlayback() {
        guard silentPlayer == nil else { return }

        // Generate 1 second of silence as WAV
        let silentData = generateSilentWAV(durationSeconds: 1, sampleRate: 16000)
        silentPlayer = try? AVAudioPlayer(data: silentData)
        silentPlayer?.numberOfLoops = -1 // infinite loop
        silentPlayer?.volume = 0.0
        silentPlayer?.play()
    }

    private func stopSilentPlayback() {
        silentPlayer?.stop()
        silentPlayer = nil
    }

    /// Generates a minimal WAV file containing silence.
    private func generateSilentWAV(durationSeconds: Int, sampleRate: Int) -> Data {
        let numSamples = sampleRate * durationSeconds
        let dataSize = numSamples * 2 // 16-bit = 2 bytes per sample
        let fileSize = 44 + dataSize // WAV header is 44 bytes

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample

        // data chunk (all zeros = silence)
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(Data(count: dataSize))

        return data
    }
}
