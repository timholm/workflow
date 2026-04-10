import Foundation
import Accelerate

/// Extracts speaker embedding vectors from audio data.
///
/// This is a simplified MFCC-based speaker encoder that runs entirely on-device.
/// For production, this should be replaced with a Core ML model (e.g., ECAPA-TDNN
/// or x-vector) for much better accuracy, but this works for the initial build.
///
/// Pipeline: audio → pre-emphasis → windowed frames → FFT → mel filterbank → DCT → MFCCs → embedding
final class SpeakerEncoder {
    static let shared = SpeakerEncoder()

    private let numMelBins = 40
    private let numMFCCs = 13
    private let embeddingDimension = 192
    private let frameLength = 400   // 25ms at 16kHz
    private let frameStep = 160     // 10ms at 16kHz
    private let fftSize = 512

    private init() {}

    /// Extract a speaker embedding from raw 16-bit PCM audio data.
    func extractEmbedding(from pcmData: Data, sampleRate: Int) -> [Float] {
        let samples = pcmDataToFloats(pcmData)
        guard samples.count > frameLength else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        // Extract MFCCs for each frame
        let mfccs = extractMFCCs(from: samples, sampleRate: sampleRate)

        // Aggregate frame-level MFCCs into a fixed-size embedding
        return aggregateToEmbedding(mfccs)
    }

    // MARK: - PCM Conversion

    private func pcmDataToFloats(_ data: Data) -> [Float] {
        let int16Count = data.count / 2
        return data.withUnsafeBytes { ptr -> [Float] in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            return (0..<int16Count).map { Float(int16Ptr[$0]) / Float(Int16.max) }
        }
    }

    // MARK: - MFCC Extraction

    private func extractMFCCs(from samples: [Float], sampleRate: Int) -> [[Float]] {
        // Pre-emphasis filter
        var emphasized = [Float](repeating: 0, count: samples.count)
        emphasized[0] = samples[0]
        for i in 1..<samples.count {
            emphasized[i] = samples[i] - 0.97 * samples[i - 1]
        }

        // Frame the signal
        let numFrames = (emphasized.count - frameLength) / frameStep + 1
        guard numFrames > 0 else { return [] }

        var allMFCCs: [[Float]] = []

        for frame in 0..<numFrames {
            let start = frame * frameStep
            let end = min(start + frameLength, emphasized.count)
            var windowedFrame = Array(emphasized[start..<end])

            // Pad if necessary
            while windowedFrame.count < fftSize {
                windowedFrame.append(0)
            }

            // Apply Hamming window
            applyHammingWindow(&windowedFrame)

            // Compute power spectrum via FFT
            let powerSpectrum = computePowerSpectrum(windowedFrame)

            // Apply mel filterbank
            let melEnergies = applyMelFilterbank(powerSpectrum, sampleRate: sampleRate)

            // Log mel energies
            let logMelEnergies = melEnergies.map { log(max($0, 1e-10)) }

            // DCT to get MFCCs
            let mfccs = dct(logMelEnergies, numCoeffs: numMFCCs)
            allMFCCs.append(mfccs)
        }

        return allMFCCs
    }

    private func applyHammingWindow(_ frame: inout [Float]) {
        let n = frame.count
        for i in 0..<n {
            let w = 0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(n - 1))
            frame[i] *= w
        }
    }

    private func computePowerSpectrum(_ frame: [Float]) -> [Float] {
        let n = frame.count
        let halfN = n / 2

        // Simple DFT for the power spectrum (for production, use vDSP FFT)
        var spectrum = [Float](repeating: 0, count: halfN + 1)

        for k in 0...halfN {
            var real: Float = 0
            var imag: Float = 0
            for i in 0..<n {
                let angle = 2.0 * Float.pi * Float(k) * Float(i) / Float(n)
                real += frame[i] * cos(angle)
                imag -= frame[i] * sin(angle)
            }
            spectrum[k] = (real * real + imag * imag) / Float(n)
        }

        return spectrum
    }

    private func applyMelFilterbank(_ spectrum: [Float], sampleRate: Int) -> [Float] {
        let lowFreq: Float = 0
        let highFreq = Float(sampleRate) / 2.0
        let lowMel = hzToMel(lowFreq)
        let highMel = hzToMel(highFreq)

        // Create mel-spaced filter center frequencies
        let melPoints = (0..<(numMelBins + 2)).map { i in
            melToHz(lowMel + Float(i) * (highMel - lowMel) / Float(numMelBins + 1))
        }

        // Convert to FFT bin indices
        let binPoints = melPoints.map { freq in
            Int(floor(Float(fftSize + 1) * freq / Float(sampleRate)))
        }

        var filterEnergies = [Float](repeating: 0, count: numMelBins)

        for m in 0..<numMelBins {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in left..<center {
                guard k < spectrum.count else { break }
                let weight = Float(k - left) / Float(max(center - left, 1))
                filterEnergies[m] += spectrum[k] * weight
            }
            for k in center..<right {
                guard k < spectrum.count else { break }
                let weight = Float(right - k) / Float(max(right - center, 1))
                filterEnergies[m] += spectrum[k] * weight
            }
        }

        return filterEnergies
    }

    private func dct(_ input: [Float], numCoeffs: Int) -> [Float] {
        let n = input.count
        return (0..<numCoeffs).map { k in
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            return sum
        }
    }

    // MARK: - Embedding Aggregation

    /// Aggregate frame-level MFCCs into a fixed-size speaker embedding.
    /// Uses mean + std of MFCCs, plus delta features.
    private func aggregateToEmbedding(_ mfccs: [[Float]]) -> [Float] {
        guard !mfccs.isEmpty, let dim = mfccs.first?.count else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        // Compute mean of each MFCC coefficient
        var mean = [Float](repeating: 0, count: dim)
        for frame in mfccs {
            for i in 0..<dim { mean[i] += frame[i] }
        }
        for i in 0..<dim { mean[i] /= Float(mfccs.count) }

        // Compute std
        var std = [Float](repeating: 0, count: dim)
        for frame in mfccs {
            for i in 0..<dim {
                let diff = frame[i] - mean[i]
                std[i] += diff * diff
            }
        }
        for i in 0..<dim { std[i] = sqrt(std[i] / Float(mfccs.count)) }

        // Compute delta means (first-order differences)
        var deltaMean = [Float](repeating: 0, count: dim)
        if mfccs.count > 1 {
            for f in 1..<mfccs.count {
                for i in 0..<dim {
                    deltaMean[i] += mfccs[f][i] - mfccs[f - 1][i]
                }
            }
            for i in 0..<dim { deltaMean[i] /= Float(mfccs.count - 1) }
        }

        // Combine: mean (13) + std (13) + deltaMean (13) = 39 base features
        // Repeat/expand to fill embedding dimension
        var embedding = mean + std + deltaMean

        // Pad or tile to reach target embedding dimension
        while embedding.count < embeddingDimension {
            // Add polynomial features (cross products of mean pairs)
            for i in 0..<min(dim, embeddingDimension - embedding.count) {
                for j in (i + 1)..<min(dim, embeddingDimension - embedding.count + 1) {
                    embedding.append(mean[i] * mean[j])
                    if embedding.count >= embeddingDimension { break }
                }
                if embedding.count >= embeddingDimension { break }
            }
        }

        // Truncate if we overshot
        embedding = Array(embedding.prefix(embeddingDimension))

        // L2 normalize
        let norm = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if norm > 0 {
            for i in 0..<embedding.count { embedding[i] /= norm }
        }

        return embedding
    }

    // MARK: - Mel Scale

    private func hzToMel(_ hz: Float) -> Float {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    private func melToHz(_ mel: Float) -> Float {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }
}
