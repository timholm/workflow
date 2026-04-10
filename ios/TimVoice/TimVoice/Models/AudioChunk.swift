import Foundation

/// A segment of raw audio captured by the recorder.
struct AudioChunk {
    let audioData: Data
    let startTime: Date
    let endTime: Date
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int

    var durationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

/// A segment of audio identified as belonging to a specific speaker.
struct SpeakerSegment {
    let audioData: Data
    let startOffset: TimeInterval  // offset within the parent chunk
    let endOffset: TimeInterval
    let speakerEmbedding: [Float]
    let isTargetSpeaker: Bool      // true = this is Tim
    let confidence: Float          // 0-1 similarity score
}

/// A transcribed segment — Tim's words only.
struct TranscriptionSegment: Codable {
    let id: String
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    let confidence: Float

    /// AI-assigned category after processing
    var category: SegmentCategory?

    /// Whether this has been synced to the server
    var synced: Bool = false
}

enum SegmentCategory: String, Codable {
    case task        // "Call Mike about the truck"
    case calendar    // "Cancel Thursday evening"
    case journal     // "Feeling good about the garden"
    case email       // "Reply to Sarah, tell her yes"
    case shopping    // "Buy more 5-gallon buckets"
    case note        // general thought worth keeping
    case conversation // talking to someone (Tim's side only)
    case discard     // background noise, filler, not useful
}
