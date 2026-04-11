import Foundation

// MARK: - Game State Transfer (iPhone -> Watch)

/// The complete game state snapshot sent from iPhone to Watch via WCSession.
/// Serialized as JSON in applicationContext so the Watch always has
/// the latest state, even if it wasn't reachable when the state changed.
struct SharedGameState: Codable {
    let pickupsToday: Int
    let currentStreak: Int
    let longestStreak: Int
    let timeAliveSeconds: TimeInterval
    let currentTaunt: String
    let activeChallenge: ChallengeTransfer?
    let screenTimeThisSession: TimeInterval
    let timestamp: Date
}

/// Watch-friendly mirror of the iPhone's Challenge model.
/// Uses a raw string for type so both sides stay decoupled.
struct ChallengeTransfer: Codable {
    let text: String
    let reward: String
    /// physical, social, creative, mindful, adventure
    let type: String
}

// MARK: - Health Data Transfer (Watch -> iPhone)

/// Batched health data the Watch sends to the iPhone every ~15 minutes.
/// Uses `transferUserInfo` so nothing is lost if the phone is unreachable.
struct HealthDataTransfer: Codable {
    let heartRateSamples: [HeartRateSample]
    let stepCount: Int
    let activeEnergyBurned: Double
    let sleepAnalysis: SleepSummary?
    let workoutSummary: WorkoutSummary?
    let collectionPeriod: DateIntervalCodable
}

struct HeartRateSample: Codable {
    let bpm: Double
    let timestamp: Date
    /// Resting, active, walking, etc.
    let motionContext: String
}

struct SleepSummary: Codable {
    let totalSleepSeconds: TimeInterval
    let deepSleepSeconds: TimeInterval
    let remSleepSeconds: TimeInterval
    let lightSleepSeconds: TimeInterval
    let awakeSeconds: TimeInterval
    let sleepStart: Date
    let sleepEnd: Date
}

struct WorkoutSummary: Codable {
    let activityType: String
    let durationSeconds: TimeInterval
    let caloriesBurned: Double
    let averageHeartRate: Double
    let startDate: Date
    let endDate: Date
}

/// DateInterval is not Codable out of the box, so we use this wrapper.
struct DateIntervalCodable: Codable {
    let start: Date
    let end: Date

    var dateInterval: DateInterval {
        DateInterval(start: start, end: end)
    }

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    init(_ dateInterval: DateInterval) {
        self.start = dateInterval.start
        self.end = dateInterval.end
    }
}

// MARK: - Challenge Completion (Watch -> iPhone)

/// Sent via `sendMessage` when Tim marks a challenge as done on the Watch.
struct ChallengeCompletionMessage: Codable {
    let challengeText: String
    let challengeType: String
    let completedAt: Date
}

// MARK: - Encoding Helpers

extension SharedGameState {
    /// Encode to a dictionary suitable for WCSession applicationContext / userInfo.
    func toDictionary() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return ["gameState": dict]
    }

    /// Decode from a WCSession dictionary.
    static func from(dictionary: [String: Any]) -> SharedGameState? {
        guard let dict = dictionary["gameState"] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? decoder.decode(SharedGameState.self, from: data)
    }
}

extension HealthDataTransfer {
    func toDictionary() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return ["healthData": dict]
    }

    static func from(dictionary: [String: Any]) -> HealthDataTransfer? {
        guard let dict = dictionary["healthData"] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? decoder.decode(HealthDataTransfer.self, from: data)
    }
}

extension ChallengeCompletionMessage {
    func toDictionary() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return ["challengeCompletion": dict]
    }

    static func from(dictionary: [String: Any]) -> ChallengeCompletionMessage? {
        guard let dict = dictionary["challengeCompletion"] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? decoder.decode(ChallengeCompletionMessage.self, from: data)
    }
}
