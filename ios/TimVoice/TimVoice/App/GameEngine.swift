import Foundation
import SwiftUI
import UIKit
import CoreMotion
import Combine

/// The brain of the game. Tracks everything about phone usage
/// and weaponizes it against Tim.
final class GameEngine: ObservableObject {
    static let shared = GameEngine()

    // MARK: - Published State

    @Published var currentTaunt: String = ""
    @Published var pickupsToday: Int = 0
    @Published var screenTimeThisSession: TimeInterval = 0
    @Published var activeChallenge: Challenge?
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0

    // MARK: - Internal

    private var sessionStart: Date?
    private var screenTimeTimer: Timer?
    private var tauntTimer: Timer?
    private var totalOffScreenToday: TimeInterval = 0
    private var lastPutDown: Date
    private let defaults = UserDefaults(suiteName: "group.community.holm.timvoice")!
    private let motionManager = CMMotionManager()

    // MARK: - Watch Sync

    /// Builds a SharedGameState snapshot and pushes it to the Watch.
    private func pushCurrentState() {
        let state = SharedGameState(
            pickupsToday: pickupsToday,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            timeAliveSeconds: totalOffScreenToday,
            currentTaunt: currentTaunt,
            activeChallenge: activeChallenge?.toChallengeTransfer(),
            screenTimeThisSession: screenTimeThisSession,
            timestamp: .now
        )
        PhoneSessionManager.shared.pushGameState(state)
    }

    /// Called when the Watch reports a challenge was completed.
    /// Credits TIME ALIVE bonus based on the challenge reward text.
    func completeChallenge(completion: ChallengeCompletionMessage) {
        guard let challenge = activeChallenge,
              challenge.text == completion.challengeText else { return }

        // Parse the bonus minutes from the reward string (e.g. "+60 min TIME ALIVE bonus")
        let bonusMinutes = parseRewardMinutes(from: challenge.reward)
        totalOffScreenToday += Double(bonusMinutes) * 60.0

        activeChallenge = nil
        saveState()
        pushCurrentState()

        print("[GameEngine] Challenge completed via Watch: +\(bonusMinutes) min TIME ALIVE")
    }

    /// Extracts the numeric minute value from a reward string like "+60 min TIME ALIVE bonus".
    private func parseRewardMinutes(from reward: String) -> Int {
        let pattern = #"\+(\d+)\s*min"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: reward, range: NSRange(reward.startIndex..., in: reward)),
              let range = Range(match.range(at: 1), in: reward) else {
            return 0
        }
        return Int(reward[range]) ?? 0
    }

    // MARK: - Computed

    var timeAliveString: String {
        let total = totalOffScreenToday
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        return String(format: "%02d:%02d", h, m)
    }

    var backgroundColor: Color {
        // Gets more aggressive the longer you're on the phone
        if screenTimeThisSession < 10 { return Color.black }
        if screenTimeThisSession < 30 { return Color(red: 0.15, green: 0, blue: 0) }
        if screenTimeThisSession < 60 { return Color(red: 0.3, green: 0, blue: 0) }
        if screenTimeThisSession < 120 { return Color(red: 0.5, green: 0, blue: 0) }
        return Color.red // you've been on too long
    }

    var streakColor: Color {
        if currentStreak >= 7 { return .green }
        if currentStreak >= 3 { return .yellow }
        return .orange
    }

    // MARK: - Init

    private init() {
        lastPutDown = .now
        loadState()
        observeAppLifecycle()
    }

    // MARK: - Phone Pickup Detection

    func phonePickedUp() {
        // Calculate time spent OFF the phone since last put-down
        let offTime = Date.now.timeIntervalSince(lastPutDown)
        totalOffScreenToday += offTime

        pickupsToday += 1
        sessionStart = .now
        screenTimeThisSession = 0

        // Start the screen time counter
        screenTimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let start = self?.sessionStart else { return }
            self?.screenTimeThisSession = Date.now.timeIntervalSince(start)
        }

        // Start cycling taunts — they get meaner the longer you stay
        deliverTaunt()
        tauntTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.deliverTaunt()
        }

        // Maybe give a challenge
        if pickupsToday > 3 {
            activeChallenge = generateChallenge()
        }

        saveState()
        pushCurrentState()
        triggerHaptic()
    }

    func phonePutDown() {
        lastPutDown = .now
        screenTimeTimer?.invalidate()
        tauntTimer?.invalidate()
        screenTimeTimer = nil
        tauntTimer = nil
        saveState()
        pushCurrentState()
    }

    // MARK: - Taunts

    private func deliverTaunt() {
        let seconds = screenTimeThisSession
        let pickups = pickupsToday

        currentTaunt = generateTaunt(screenTime: seconds, pickups: pickups)
        pushCurrentState()
    }

    private func generateTaunt(screenTime: TimeInterval, pickups: Int) -> String {
        // Under 5 seconds — you might just be checking something
        if screenTime < 5 {
            return pickQuickTaunts()
        }

        // 5-30 seconds — getting suspicious
        if screenTime < 30 {
            return pickMediumTaunts(pickups: pickups)
        }

        // 30-60 seconds — you're scrolling
        if screenTime < 60 {
            return pickLongTaunts()
        }

        // 1-3 minutes — getting aggressive
        if screenTime < 180 {
            return pickAggressiveTaunts(pickups: pickups)
        }

        // 3+ minutes — full attack mode
        return pickNuclearTaunts(screenTime: screenTime)
    }

    private func pickQuickTaunts() -> String {
        [
            "Oh. You again.",
            "What do you need?",
            "Make it quick.",
            "The sun is out, you know.",
            "This better be important.",
            "Hi. Bye.",
        ].randomElement()!
    }

    private func pickMediumTaunts(pickups: Int) -> String {
        [
            "Still here?",
            "That's \(pickups) times today. You counting?",
            "Your hands could be building something right now.",
            "Nothing on here is real. Go outside.",
            "Every second here is a second not lived.",
            "The garden doesn't water itself.",
            "Who are you avoiding?",
        ].randomElement()!
    }

    private func pickLongTaunts() -> String {
        [
            "30 seconds. You're officially scrolling.",
            "You said you wanted to be screenless.",
            "Remember when you had that idea? It's dying right now.",
            "This is the part of your life you won't remember.",
            "PUT. IT. DOWN.",
            "Your future self is watching. Disappointed.",
            "Is this what alive feels like to you?",
        ].randomElement()!
    }

    private func pickAggressiveTaunts(pickups: Int) -> String {
        [
            "ONE MINUTE on a screen you said you'd quit.",
            "Pickup #\(pickups). You're losing.",
            "The phone is winning and you're letting it.",
            "This is addiction. You know that, right?",
            "Every app on this phone was designed to trap you. It's working.",
            "You have ONE LIFE. You're spending it here.",
            "Your kids will do what you do, not what you say.",
        ].randomElement()!
    }

    private func pickNuclearTaunts(screenTime: TimeInterval) -> String {
        let minutes = Int(screenTime / 60)
        return [
            "\(minutes) MINUTES. On a phone. That you said you'd stop using.",
            "Congratulations. You are the product.",
            "You could have run a mile in this time.",
            "This phone doesn't love you back.",
            "Every minute here is a minute stolen from someone who needs you present.",
            "You are choosing pixels over reality. Right now. This moment.",
            "The system is recording this. Your future self will read it on paper and feel this.",
        ].randomElement()!
    }

    // MARK: - Challenges

    private func generateChallenge() -> Challenge {
        let challenges = [
            Challenge(
                text: "Go outside and walk for 10 minutes. No phone.",
                reward: "+60 min TIME ALIVE bonus",
                type: .physical
            ),
            Challenge(
                text: "Call someone you haven't talked to in a month. A real call.",
                reward: "+30 min TIME ALIVE bonus",
                type: .social
            ),
            Challenge(
                text: "Write one page in your notebook. By hand.",
                reward: "+45 min TIME ALIVE bonus",
                type: .creative
            ),
            Challenge(
                text: "Do 20 pushups. Right now. Floor.",
                reward: "+15 min TIME ALIVE bonus",
                type: .physical
            ),
            Challenge(
                text: "Sit still for 5 minutes. No phone. No music. Just exist.",
                reward: "+30 min TIME ALIVE bonus",
                type: .mindful
            ),
            Challenge(
                text: "Go make food. From scratch. Not a microwave.",
                reward: "+90 min TIME ALIVE bonus",
                type: .creative
            ),
            Challenge(
                text: "Take a cold shower. 2 minutes minimum.",
                reward: "+30 min TIME ALIVE bonus",
                type: .physical
            ),
            Challenge(
                text: "Look out a window for 60 seconds. Just look.",
                reward: "+10 min TIME ALIVE bonus",
                type: .mindful
            ),
            Challenge(
                text: "Text 3 people 'thinking of you' then PUT THIS DOWN.",
                reward: "+20 min TIME ALIVE bonus",
                type: .social
            ),
            Challenge(
                text: "Drive to the beach. Leave the phone in the car.",
                reward: "+120 min TIME ALIVE bonus",
                type: .adventure
            ),
        ]
        return challenges.randomElement()!
    }

    // MARK: - Streaks

    /// A streak day = less than 30 total minutes of screen time
    private func updateStreak() {
        let screenTimeToday = pickupsToday > 0 ? screenTimeThisSession : 0
        let totalScreen = screenTimeToday // simplified — would accumulate across sessions

        if totalScreen < 1800 { // under 30 minutes
            // Streak continues
        } else {
            currentStreak = 0
        }

        if currentStreak > longestStreak {
            longestStreak = currentStreak
        }
    }

    // MARK: - Haptics

    private func triggerHaptic() {
        let generator = UINotificationFeedbackGenerator()
        // Warning haptic every time — you shouldn't be here
        generator.notificationOccurred(.warning)
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.phonePutDown()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.phonePickedUp()
        }

        // Reset daily at midnight
        NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.resetDaily()
        }
    }

    // MARK: - Persistence

    private func saveState() {
        defaults.set(pickupsToday, forKey: "game_pickups_today")
        defaults.set(currentStreak, forKey: "game_streak")
        defaults.set(longestStreak, forKey: "game_longest_streak")
        defaults.set(totalOffScreenToday, forKey: "game_off_screen")
        defaults.set(lastPutDown.timeIntervalSince1970, forKey: "game_last_putdown")
        defaults.set(Date.now.timeIntervalSince1970, forKey: "game_last_save_date")
    }

    private func loadState() {
        let lastSave = Date(timeIntervalSince1970: defaults.double(forKey: "game_last_save_date"))
        let isToday = Calendar.current.isDateInToday(lastSave)

        if isToday {
            pickupsToday = defaults.integer(forKey: "game_pickups_today")
            totalOffScreenToday = defaults.double(forKey: "game_off_screen")
        } else {
            // New day — check if yesterday was a streak day
            let yesterdayPickups = defaults.integer(forKey: "game_pickups_today")
            if yesterdayPickups <= 20 { // reasonable threshold
                currentStreak = defaults.integer(forKey: "game_streak") + 1
            } else {
                currentStreak = 0
            }
            pickupsToday = 0
            totalOffScreenToday = 0
        }

        longestStreak = defaults.integer(forKey: "game_longest_streak")
        currentStreak = max(currentStreak, defaults.integer(forKey: "game_streak"))

        let putdownTs = defaults.double(forKey: "game_last_putdown")
        lastPutDown = putdownTs > 0 ? Date(timeIntervalSince1970: putdownTs) : .now
    }

    private func resetDaily() {
        updateStreak()
        pickupsToday = 0
        totalOffScreenToday = 0
        saveState()
    }
}

// MARK: - Models

struct Challenge {
    let text: String
    let reward: String
    let type: ChallengeType

    enum ChallengeType: String {
        case physical
        case social
        case creative
        case mindful
        case adventure
    }

    func toChallengeTransfer() -> ChallengeTransfer {
        ChallengeTransfer(text: text, reward: reward, type: type.rawValue)
    }
}
