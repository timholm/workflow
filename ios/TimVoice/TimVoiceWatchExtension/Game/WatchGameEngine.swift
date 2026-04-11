import Foundation
import WatchKit
import Combine
import HealthKit

/// The Watch game engine. The Ally.
///
/// This is NOT a copy of the iPhone's GameEngine. The Watch does NOT
/// detect pickups. It receives state from the iPhone and does one thing:
/// REWARDS Tim for staying off the phone.
///
/// The phone punishes. The Watch celebrates.
/// The phone is red. The Watch is green.
/// The phone taunts. The Watch encourages.
final class WatchGameEngine: ObservableObject {
    static let shared = WatchGameEngine()

    // MARK: - Published State (from iPhone)

    @Published var pickupsToday: Int = 0
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0
    @Published var timeAliveSeconds: TimeInterval = 0
    @Published var currentTaunt: String = ""
    @Published var screenTimeThisSession: TimeInterval = 0

    // MARK: - Published State (Watch-generated)

    @Published var activeChallenge: ChallengeTransfer?
    @Published var encouragement: String = "Put the phone down. Live."
    @Published var isPhoneFarAway: Bool = false

    // MARK: - Internal

    private let device = WKInterfaceDevice.current()
    private var encouragementTimer: Timer?
    private var rewardCheckTimer: Timer?
    private var lastRewardTime: Date = .now
    private var lastEncouragementIndex: Int = -1
    private var phoneFarAwaySince: Date?
    private let healthStore = HKHealthStore()
    private var heartRateQuery: HKObserverQuery?

    /// Streak milestones that trigger extra celebration haptics.
    private let streakMilestones: Set<Int> = [3, 7, 14, 30, 60, 90, 100, 365]

    // MARK: - Init

    private init() {
        startEncouragementRotation()
        startRewardCheckTimer()
    }

    // MARK: - State Updates from iPhone

    /// Called by WatchSessionManager when new game state arrives.
    func updateFromSharedState(_ state: SharedGameState) {
        let previousStreak = currentStreak

        pickupsToday = state.pickupsToday
        currentStreak = state.currentStreak
        longestStreak = state.longestStreak
        timeAliveSeconds = state.timeAliveSeconds
        currentTaunt = state.currentTaunt
        activeChallenge = state.activeChallenge
        screenTimeThisSession = state.screenTimeThisSession

        // Check for streak milestone
        if currentStreak != previousStreak && streakMilestones.contains(currentStreak) {
            celebrateStreakMilestone(currentStreak)
        }

        // Refresh encouragement with new data
        rotateEncouragement()
    }

    // MARK: - Reward Haptics

    /// Every 30 minutes off the phone, the Watch rewards Tim.
    /// The phone would NEVER do this. The Watch is the Ally.
    private func startRewardCheckTimer() {
        rewardCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForTimeReward()
        }
    }

    private func checkForTimeReward() {
        let timeSinceLastReward = Date.now.timeIntervalSince(lastRewardTime)

        // Reward every 30 minutes of being alive (off phone)
        if timeSinceLastReward >= 1800 {
            deliverTimeReward()
            lastRewardTime = .now
        }
    }

    /// Success haptic + encouraging message for sustained time off phone.
    private func deliverTimeReward() {
        device.play(.success)

        let minutes = Int(timeAliveSeconds / 60)
        let rewardMessages = [
            "\(minutes) minutes free. You're doing it.",
            "\(minutes) minutes of real life. Well done.",
            "Half hour of freedom earned.",
            "Your brain is healing. Keep going.",
            "This is what being present feels like.",
        ]
        encouragement = rewardMessages.randomElement() ?? "Keep going."
    }

    /// Streak milestones get extra celebration — repeated success haptics.
    private func celebrateStreakMilestone(_ days: Int) {
        // Multiple haptic bursts for milestones
        let burstCount = min(days / 3, 5) // up to 5 bursts
        for i in 0..<max(burstCount, 2) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { [weak self] in
                self?.device.play(.success)
            }
        }

        encouragement = "\(days) day streak. You are transforming."
    }

    /// Called when Tim marks a challenge as done on the Watch.
    func completeChallenge() {
        guard let challenge = activeChallenge else { return }

        // Notification haptic for challenge completion
        device.play(.notification)

        let completion = ChallengeCompletionMessage(
            challengeText: challenge.text,
            challengeType: challenge.type,
            completedAt: .now
        )

        // Send to iPhone via WatchSessionManager
        WatchSessionManager.shared.sendChallengeCompletion(completion)

        encouragement = "Challenge complete. The real world rewards you."
        activeChallenge = nil
    }

    /// Called by WatchSessionManager when the iPhone confirms challenge completion.
    func challengeCompletionConfirmed() {
        device.play(.success)
    }

    // MARK: - Phone Distance

    /// Called when the phone becomes unreachable. This is a CELEBRATION.
    func phoneWentFarAway() {
        isPhoneFarAway = true
        phoneFarAwaySince = .now
        device.play(.success)
        encouragement = "Phone is far away. This is freedom."
    }

    func phoneIsNearby() {
        isPhoneFarAway = false
        phoneFarAwaySince = nil
    }

    /// The longer the phone is far away, the more positive messages become.
    private var phoneFarAwayDuration: TimeInterval {
        guard let since = phoneFarAwaySince else { return 0 }
        return Date.now.timeIntervalSince(since)
    }

    // MARK: - Encouragement Messages

    /// The opposite of the iPhone's taunts.
    /// These are warm, quiet, real. No exclamation marks. No hype.
    /// Just genuine presence.
    private func startEncouragementRotation() {
        encouragementTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.rotateEncouragement()
        }
    }

    private func rotateEncouragement() {
        let messages = buildEncouragementMessages()
        guard !messages.isEmpty else { return }

        // Avoid repeating the same message
        var index: Int
        repeat {
            index = Int.random(in: 0..<messages.count)
        } while index == lastEncouragementIndex && messages.count > 1
        lastEncouragementIndex = index

        encouragement = messages[index]
    }

    /// Builds context-aware encouragement based on current state.
    private func buildEncouragementMessages() -> [String] {
        var messages: [String] = []

        // Time-based messages
        let minutes = Int(timeAliveSeconds / 60)
        if minutes > 0 {
            messages.append("\(minutes) minutes free. Keep going.")
        }
        if minutes >= 60 {
            let hours = minutes / 60
            messages.append("\(hours) hour\(hours == 1 ? "" : "s") of real life today.")
        }

        // Streak-based messages
        if currentStreak >= 30 {
            messages.append("\(currentStreak) days. You've rewired your brain.")
        } else if currentStreak >= 14 {
            messages.append("\(currentStreak) days strong. Habits are forming.")
        } else if currentStreak >= 7 {
            messages.append("One week. Your brain is changing.")
        } else if currentStreak >= 3 {
            messages.append("\(currentStreak) day streak. Momentum.")
        }

        // Phone distance messages (the best ones)
        if isPhoneFarAway {
            let farMinutes = Int(phoneFarAwayDuration / 60)
            messages.append("Phone is far away. This is freedom.")
            messages.append("No screen. Just you and the world.")
            if farMinutes > 10 {
                messages.append("\(farMinutes) minutes without the phone nearby. Beautiful.")
            }
            if farMinutes > 30 {
                messages.append("Half an hour phone-free. You're living proof it's possible.")
            }
            if farMinutes > 60 {
                messages.append("Over an hour without the phone. This is who you really are.")
            }
        }

        // Low pickup messages
        if pickupsToday == 0 {
            messages.append("Zero pickups today. Perfect.")
        } else if pickupsToday <= 3 {
            messages.append("Only \(pickupsToday) pickup\(pickupsToday == 1 ? "" : "s") today. That's restraint.")
        }

        // Universal messages — always applicable
        messages.append(contentsOf: [
            "You're doing it.",
            "This is what being present feels like.",
            "The world is right here.",
            "Breathe. You don't need the screen.",
            "Your attention is yours.",
            "Stay here. This moment is real.",
            "The phone can wait. Life can't.",
        ])

        return messages
    }

    // MARK: - Health Data Collection

    func startHealthCollection() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!

        let typesToRead: Set<HKObjectType> = [heartRateType, stepType, energyType, sleepType]

        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { [weak self] success, _ in
            guard success else { return }
            self?.startHeartRateObserver()
            self?.queryStepsAndEnergy()
        }
    }

    private func startHeartRateObserver() {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!

        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            self?.fetchLatestHeartRate()
            completionHandler()
        }

        healthStore.execute(query)
        heartRateQuery = query
    }

    private func fetchLatestHeartRate() {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            let heartRateSample = HeartRateSample(
                bpm: bpm,
                timestamp: sample.startDate,
                motionContext: "unknown"
            )
            DispatchQueue.main.async {
                WatchSessionManager.shared.appendHeartRateSample(heartRateSample)
            }
        }
        healthStore.execute(query)
    }

    private func queryStepsAndEnergy() {
        let now = Date.now
        let startOfDay = Calendar.current.startOfDay(for: now)

        // Steps
        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        let stepsQuery = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, result, _ in
            let steps = Int(result?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
            DispatchQueue.main.async {
                WatchSessionManager.shared.updateStepCount(steps)
            }
        }
        healthStore.execute(stepsQuery)

        // Active energy
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let energyQuery = HKStatisticsQuery(
            quantityType: energyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, result, _ in
            let calories = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            DispatchQueue.main.async {
                WatchSessionManager.shared.updateActiveEnergy(calories)
            }
        }
        healthStore.execute(energyQuery)
    }

    // MARK: - Computed Properties

    var timeAliveString: String {
        let total = timeAliveSeconds
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        return String(format: "%02d:%02d", h, m)
    }

    /// Green to blue gradient — the emotional inverse of the phone's black-to-red.
    /// More time alive = more vibrant.
    var backgroundGradient: [WatchColor] {
        let hours = timeAliveSeconds / 3600

        if hours < 1 {
            // Just starting — soft green
            return [
                WatchColor(red: 0.0, green: 0.15, blue: 0.1),
                WatchColor(red: 0.0, green: 0.1, blue: 0.15),
            ]
        } else if hours < 3 {
            // Getting going — brighter green
            return [
                WatchColor(red: 0.0, green: 0.3, blue: 0.15),
                WatchColor(red: 0.0, green: 0.15, blue: 0.3),
            ]
        } else if hours < 6 {
            // Strong session — rich green-blue
            return [
                WatchColor(red: 0.0, green: 0.4, blue: 0.2),
                WatchColor(red: 0.0, green: 0.2, blue: 0.4),
            ]
        } else {
            // Legendary — full vibrant
            return [
                WatchColor(red: 0.0, green: 0.5, blue: 0.25),
                WatchColor(red: 0.1, green: 0.25, blue: 0.5),
            ]
        }
    }

    var streakColor: WatchColor {
        if currentStreak >= 7 { return WatchColor(red: 0, green: 1, blue: 0.5) }
        if currentStreak >= 3 { return WatchColor(red: 1, green: 0.9, blue: 0) }
        return WatchColor(red: 1, green: 0.6, blue: 0)
    }

    // MARK: - Cleanup

    func invalidate() {
        encouragementTimer?.invalidate()
        rewardCheckTimer?.invalidate()
        encouragementTimer = nil
        rewardCheckTimer = nil
        if let query = heartRateQuery {
            healthStore.stop(query)
        }
    }
}

// MARK: - Watch Color Helper

/// Simple color container that avoids importing SwiftUI into the engine.
/// The View layer converts these to SwiftUI Color values.
struct WatchColor {
    let red: Double
    let green: Double
    let blue: Double
}
