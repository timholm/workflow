import Foundation
import UserNotifications
import WatchKit

// MARK: - Notification Categories

enum WatchNotificationCategory: String, CaseIterable {
    case pickupTaunt       = "pickup_taunt"
    case challengeIssued   = "challenge_issued"
    case streakUpdate      = "streak_update"
    case timeAliveMilestone = "time_alive_milestone"
    case morningBriefReady = "morning_brief_ready"
    case healthInsight     = "health_insight"
}

// MARK: - Notification Actions

enum WatchNotificationAction: String {
    case startChallenge = "START_CHALLENGE"
    case dismissTaunt   = "DISMISS_TAUNT"
}

// MARK: - Haptic Map

/// Maps each category to its WatchKit haptic. The watch is the ally —
/// every vibration means something.
private let hapticMap: [WatchNotificationCategory: WKHapticType] = [
    .pickupTaunt:        .directionDown,   // sinking feeling
    .challengeIssued:    .notification,     // something to do
    .streakUpdate:       .success,          // pride
    .timeAliveMilestone: .success,          // you earned it
    .morningBriefReady:  .click,            // gentle tap
    .healthInsight:      .click,            // info
]

// MARK: - Streak Milestones

private let streakMilestones: Set<Int> = [3, 7, 14, 30, 60, 90, 180, 365]

// MARK: - TIME ALIVE Milestones (seconds)

private let timeAliveMilestones: [(seconds: TimeInterval, label: String)] = [
    (3600,     "1 HOUR off the phone."),
    (7200,     "2 HOURS off the phone."),
    (14400,    "4 HOURS. Half a waking day reclaimed."),
    (28800,    "8 HOURS. A full workday of being present."),
    (43200,    "12 HOURS. You barely touched it today."),
]

// MARK: - Watch Notification Handler

/// Handles all notification lifecycle on the Watch.
/// The Watch is the ally. Every buzz is intentional.
final class WatchNotificationHandler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationHandler()

    private let center = UNUserNotificationCenter.current()
    private let device = WKInterfaceDevice.current()

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Call once at app launch to register categories, actions, and delegate.
    func configure() {
        center.delegate = self
        registerCategories()
        requestAuthorization()
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[WatchNotif] authorization error: \(error.localizedDescription)")
            }
            if !granted {
                print("[WatchNotif] notifications denied. the watch is muted.")
            }
        }
    }

    private func registerCategories() {
        let startAction = UNNotificationAction(
            identifier: WatchNotificationAction.startChallenge.rawValue,
            title: "START",
            options: .foreground
        )

        let dismissAction = UNNotificationAction(
            identifier: WatchNotificationAction.dismissTaunt.rawValue,
            title: "Fine.",
            options: .destructive
        )

        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: WatchNotificationCategory.pickupTaunt.rawValue,
                actions: [dismissAction],
                intentIdentifiers: [],
                options: .customDismissAction
            ),
            UNNotificationCategory(
                identifier: WatchNotificationCategory.challengeIssued.rawValue,
                actions: [startAction],
                intentIdentifiers: [],
                options: .customDismissAction
            ),
            UNNotificationCategory(
                identifier: WatchNotificationCategory.streakUpdate.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: WatchNotificationCategory.timeAliveMilestone.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: WatchNotificationCategory.morningBriefReady.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: WatchNotificationCategory.healthInsight.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ]

        center.setNotificationCategories(categories)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let categoryID = notification.request.content.categoryIdentifier

        // Play the correct haptic
        if let category = WatchNotificationCategory(rawValue: categoryID) {
            playHaptic(for: category)
        }

        // Always show the notification on the watch face
        completionHandler([.banner, .sound])
    }

    /// Called when the user taps a notification or an action button.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryID = response.notification.request.content.categoryIdentifier
        let actionID = response.actionIdentifier

        switch actionID {
        case WatchNotificationAction.startChallenge.rawValue:
            handleChallengeStart(from: response.notification)

        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification itself
            handleDefaultTap(category: categoryID)

        case UNNotificationDismissActionIdentifier:
            // Dismissed — nothing to do
            break

        case WatchNotificationAction.dismissTaunt.rawValue:
            // "Fine." — acknowledged the taunt
            break

        default:
            break
        }

        completionHandler()
    }

    // MARK: - Haptic Playback

    private func playHaptic(for category: WatchNotificationCategory) {
        guard let haptic = hapticMap[category] else { return }

        switch category {
        case .streakUpdate:
            // Celebratory: three rapid success pulses
            playRepeatedHaptic(haptic, count: 3, interval: 0.3)

        case .pickupTaunt:
            // Sinking: one heavy direction-down
            device.play(haptic)

        case .timeAliveMilestone:
            // Earned it: two success taps
            playRepeatedHaptic(haptic, count: 2, interval: 0.4)

        default:
            device.play(haptic)
        }
    }

    private func playRepeatedHaptic(_ type: WKHapticType, count: Int, interval: TimeInterval) {
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) { [weak self] in
                self?.device.play(type)
            }
        }
    }

    // MARK: - Action Handlers

    private func handleChallengeStart(from notification: UNNotification) {
        let userInfo = notification.request.content.userInfo

        // Decode challenge from payload and push it into the engine
        if let data = userInfo["challenge"] as? Data,
           let challenge = try? JSONDecoder().decode(ChallengeTransfer.self, from: data) {
            DispatchQueue.main.async {
                WatchGameEngine.shared.activeChallenge = challenge
            }
        }
    }

    private func handleDefaultTap(category: String) {
        // Tapping any notification opens the Watch app to the relevant view.
        // The app's root view should observe WatchGameEngine state to navigate.
        switch WatchNotificationCategory(rawValue: category) {
        case .challengeIssued:
            // Engine already has the challenge; the UI will show ChallengeView
            break
        case .pickupTaunt:
            // Nothing extra — the taunt is already displayed
            break
        default:
            break
        }
    }

    // MARK: - Fire Immediate Notifications

    /// Phone pickup detected — deliver a taunt to the wrist.
    func firePickupTaunt(_ taunt: String) {
        let content = UNMutableNotificationContent()
        content.title = "PUT IT DOWN."
        content.body = taunt
        content.categoryIdentifier = WatchNotificationCategory.pickupTaunt.rawValue
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "pickup_\(UUID().uuidString)",
            content: content,
            trigger: nil // immediate
        )

        center.add(request) { error in
            if let error = error {
                print("[WatchNotif] pickup taunt error: \(error.localizedDescription)")
            }
        }

        playHaptic(for: .pickupTaunt)
    }

    /// New challenge issued from the phone or engine.
    func fireChallengeIssued(_ challenge: ChallengeTransfer) {
        let content = UNMutableNotificationContent()
        content.title = "CHALLENGE."
        content.body = challenge.text
        content.categoryIdentifier = WatchNotificationCategory.challengeIssued.rawValue
        content.sound = .default

        // Attach challenge data for the action handler
        if let data = try? JSONEncoder().encode(challenge) {
            content.userInfo["challenge"] = data
        }

        let request = UNNotificationRequest(
            identifier: "challenge_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
        playHaptic(for: .challengeIssued)
    }

    /// Streak milestone reached.
    func fireStreakUpdate(days: Int) {
        guard streakMilestones.contains(days) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(days)-DAY STREAK."
        content.body = streakMessage(for: days)
        content.categoryIdentifier = WatchNotificationCategory.streakUpdate.rawValue
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "streak_\(days)_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
        playHaptic(for: .streakUpdate)
    }

    /// TIME ALIVE milestone — you've been off the phone for N hours.
    func fireTimeAliveMilestone(seconds: TimeInterval) {
        guard let milestone = timeAliveMilestones.first(where: { $0.seconds == seconds }) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "TIME ALIVE"
        content.body = milestone.label
        content.categoryIdentifier = WatchNotificationCategory.timeAliveMilestone.rawValue
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "alive_\(Int(seconds))_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
        playHaptic(for: .timeAliveMilestone)
    }

    /// Morning brief is printing.
    func fireMorningBriefReady() {
        let content = UNMutableNotificationContent()
        content.title = "MORNING BRIEF"
        content.body = "Your morning brief is printing."
        content.categoryIdentifier = WatchNotificationCategory.morningBriefReady.rawValue
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "morning_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
        playHaptic(for: .morningBriefReady)
    }

    /// Health insight — periodic observation.
    func fireHealthInsight(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "BODY DATA"
        content.body = message
        content.categoryIdentifier = WatchNotificationCategory.healthInsight.rawValue
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "health_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
        playHaptic(for: .healthInsight)
    }

    // MARK: - Scheduled Notifications

    /// Schedules local notifications for TIME ALIVE milestones.
    /// Called when the phone is put down — sets timers for 1hr, 2hr, 4hr, 8hr off-phone.
    func scheduleRewardNotifications(from putDownTime: Date = Date()) {
        // Cancel any existing milestone notifications first
        let milestoneIDs = timeAliveMilestones.map { "scheduled_alive_\(Int($0.seconds))" }
        center.removePendingNotificationRequests(withIdentifiers: milestoneIDs)

        for milestone in timeAliveMilestones {
            let content = UNMutableNotificationContent()
            content.title = "TIME ALIVE"
            content.body = milestone.label
            content.categoryIdentifier = WatchNotificationCategory.timeAliveMilestone.rawValue
            content.sound = .default

            let triggerDate = putDownTime.addingTimeInterval(milestone.seconds)
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: triggerDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let request = UNNotificationRequest(
                identifier: "scheduled_alive_\(Int(milestone.seconds))",
                content: content,
                trigger: trigger
            )

            center.add(request) { error in
                if let error = error {
                    print("[WatchNotif] schedule error for \(milestone.label): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Schedule the daily morning brief notification at 6:00 AM.
    func scheduleMorningBrief() {
        let content = UNMutableNotificationContent()
        content.title = "MORNING BRIEF"
        content.body = "Your morning brief is printing."
        content.categoryIdentifier = WatchNotificationCategory.morningBriefReady.rawValue
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = 6
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: "morning_brief_daily",
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("[WatchNotif] morning brief schedule error: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel all pending reward/milestone notifications.
    /// Called when a streak breaks or phone is picked up.
    func cancelAllPending() {
        center.removeAllPendingNotificationRequests()
    }

    /// Cancel only the TIME ALIVE milestone notifications (preserve morning brief, etc.)
    func cancelTimeAliveMilestones() {
        let milestoneIDs = timeAliveMilestones.map { "scheduled_alive_\(Int($0.seconds))" }
        center.removePendingNotificationRequests(withIdentifiers: milestoneIDs)
    }

    // MARK: - Streak Messages

    private func streakMessage(for days: Int) -> String {
        switch days {
        case 3:   return "3 days. You're proving something."
        case 7:   return "One week. The habit is forming."
        case 14:  return "Two weeks. You're not the same person."
        case 30:  return "30 DAYS. A month of being present."
        case 60:  return "60 days. Most people never get here."
        case 90:  return "90 days. This is who you are now."
        case 180: return "Half a year. The phone lost."
        case 365: return "ONE YEAR. You won."
        default:  return "\(days) days of choosing reality."
        }
    }
}
