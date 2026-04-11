import Foundation
import WatchConnectivity
import Combine
import WatchKit

/// Watch-side WCSession manager. The bridge between the Enemy (iPhone)
/// and the Ally (Watch).
///
/// Receives game state from the iPhone so the Watch always knows the score.
/// Sends health data back to the iPhone in batches.
/// Monitors reachability — when the phone is far away, that's a GOOD thing.
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    // MARK: - Published State

    /// True when the iPhone is NOT reachable. This is a reward state.
    @Published var isPhoneFarAway: Bool = true

    /// How long the phone has been unreachable (seconds).
    @Published var phoneFarAwayDuration: TimeInterval = 0

    /// The most recent game state received from the iPhone.
    @Published var latestGameState: SharedGameState?

    // MARK: - Internal

    private var session: WCSession?
    private var phoneFarAwaySince: Date?
    private var farAwayTimer: Timer?
    private let healthBatchInterval: TimeInterval = 15 * 60 // 15 minutes
    private var healthBatchTimer: Timer?
    private var pendingHealthSamples: [HeartRateSample] = []
    private var pendingStepCount: Int = 0
    private var pendingActiveEnergy: Double = 0
    private var pendingSleepSummary: SleepSummary?
    private var pendingWorkoutSummary: WorkoutSummary?
    private var batchStart: Date = .now

    private let appGroupID = "group.community.holm.timvoice"

    // MARK: - Init

    override private init() {
        super.init()
    }

    // MARK: - Session Activation

    func activateSession() {
        guard WCSession.isSupported() else { return }

        let wcSession = WCSession.default
        wcSession.delegate = self
        wcSession.activate()
        session = wcSession

        // Load last known state from shared UserDefaults
        loadStateFromAppGroup()

        // Start monitoring phone distance
        startPhoneDistanceMonitoring()

        // Start health data batch timer
        startHealthBatchTimer()
    }

    // MARK: - Phone Distance Monitoring

    /// We WANT the phone to be far away. That means Tim is living.
    private func startPhoneDistanceMonitoring() {
        // Check reachability every 5 seconds
        farAwayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updatePhoneDistance()
        }
    }

    private func updatePhoneDistance() {
        guard let session = session else {
            isPhoneFarAway = true
            return
        }

        let wasReachable = !isPhoneFarAway
        let isReachable = session.isReachable

        if isReachable {
            // Phone is nearby — not ideal, but we don't punish
            isPhoneFarAway = false
            phoneFarAwaySince = nil
            phoneFarAwayDuration = 0
        } else {
            // Phone is far away — this is the goal
            isPhoneFarAway = true
            if phoneFarAwaySince == nil {
                phoneFarAwaySince = .now
            }
            phoneFarAwayDuration = Date.now.timeIntervalSince(phoneFarAwaySince ?? .now)

            // If phone just became unreachable, celebrate
            if wasReachable {
                WatchGameEngine.shared.phoneWentFarAway()
            }
        }
    }

    // MARK: - Sending Health Data to iPhone

    private func startHealthBatchTimer() {
        healthBatchTimer = Timer.scheduledTimer(
            withTimeInterval: healthBatchInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendHealthBatch()
        }
    }

    func appendHeartRateSample(_ sample: HeartRateSample) {
        pendingHealthSamples.append(sample)
    }

    func updateStepCount(_ steps: Int) {
        pendingStepCount = steps
    }

    func updateActiveEnergy(_ calories: Double) {
        pendingActiveEnergy = calories
    }

    func updateSleepSummary(_ summary: SleepSummary) {
        pendingSleepSummary = summary
    }

    func updateWorkoutSummary(_ summary: WorkoutSummary) {
        pendingWorkoutSummary = summary
    }

    /// Flush all collected health data to the iPhone.
    /// Uses `transferUserInfo` — queued and delivered reliably even if
    /// the phone is not reachable right now.
    func sendHealthBatch() {
        guard !pendingHealthSamples.isEmpty || pendingStepCount > 0 else { return }

        let transfer = HealthDataTransfer(
            heartRateSamples: pendingHealthSamples,
            stepCount: pendingStepCount,
            activeEnergyBurned: pendingActiveEnergy,
            sleepAnalysis: pendingSleepSummary,
            workoutSummary: pendingWorkoutSummary,
            collectionPeriod: DateIntervalCodable(start: batchStart, end: .now)
        )

        let dict = transfer.toDictionary()
        session?.transferUserInfo(dict)

        // Reset batch
        pendingHealthSamples.removeAll()
        pendingStepCount = 0
        pendingActiveEnergy = 0
        pendingSleepSummary = nil
        pendingWorkoutSummary = nil
        batchStart = .now
    }

    // MARK: - Sending Challenge Completion

    /// Called when Tim taps "DONE" on a challenge on the Watch.
    /// Uses `sendMessage` for immediate delivery with reply confirmation,
    /// falls back to `transferUserInfo` if the phone is unreachable.
    func sendChallengeCompletion(_ completion: ChallengeCompletionMessage) {
        let dict = completion.toDictionary()

        guard let session = session, session.isReachable else {
            // Phone is far away — queue it up
            session?.transferUserInfo(dict)
            return
        }

        session.sendMessage(dict, replyHandler: { reply in
            // iPhone acknowledged the completion
            DispatchQueue.main.async {
                WatchGameEngine.shared.challengeCompletionConfirmed()
            }
        }, errorHandler: { [weak self] error in
            // Fallback to queued transfer
            self?.session?.transferUserInfo(dict)
        })
    }

    // MARK: - Sending Audio Files

    /// Transfers a Watch mic recording to the iPhone for voice processing.
    func sendAudioFile(at url: URL, metadata: [String: Any] = [:]) {
        session?.transferFile(url, metadata: metadata)
    }

    // MARK: - App Group Shared Defaults Fallback

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private func saveStateToAppGroup(_ state: SharedGameState) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: "watch_shared_game_state")
        }
    }

    private func loadStateFromAppGroup() {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: "watch_shared_game_state") else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let state = try? decoder.decode(SharedGameState.self, from: data) {
            latestGameState = state
            WatchGameEngine.shared.updateFromSharedState(state)
        }
    }

    // MARK: - Cleanup

    func invalidate() {
        farAwayTimer?.invalidate()
        healthBatchTimer?.invalidate()
        farAwayTimer = nil
        healthBatchTimer = nil
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            DispatchQueue.main.async { [weak self] in
                self?.updatePhoneDistance()
            }
        }
    }

    /// Primary channel for receiving game state from the iPhone.
    /// applicationContext is replaced on every send — always the latest snapshot.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = SharedGameState.from(dictionary: applicationContext) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.latestGameState = state
            self?.saveStateToAppGroup(state)
            WatchGameEngine.shared.updateFromSharedState(state)
        }
    }

    /// Handles direct messages from the iPhone (e.g., immediate taunt updates).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let state = SharedGameState.from(dictionary: message) {
            DispatchQueue.main.async { [weak self] in
                self?.latestGameState = state
                self?.saveStateToAppGroup(state)
                WatchGameEngine.shared.updateFromSharedState(state)
            }
        }
    }

    /// Handles messages from the iPhone that expect a reply.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if let state = SharedGameState.from(dictionary: message) {
            DispatchQueue.main.async { [weak self] in
                self?.latestGameState = state
                self?.saveStateToAppGroup(state)
                WatchGameEngine.shared.updateFromSharedState(state)
            }
        }
        replyHandler(["status": "received"])
    }

    /// Handles queued userInfo transfers from the iPhone (e.g., historical data).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let state = SharedGameState.from(dictionary: userInfo) {
            DispatchQueue.main.async { [weak self] in
                self?.latestGameState = state
                self?.saveStateToAppGroup(state)
                WatchGameEngine.shared.updateFromSharedState(state)
            }
        }
    }
}
