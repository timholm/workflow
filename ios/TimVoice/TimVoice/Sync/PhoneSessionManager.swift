import Foundation
import WatchConnectivity

/// iPhone-side WatchConnectivity manager.
///
/// Responsibilities:
/// - Pushes game state snapshots to the Watch via `updateApplicationContext`
/// - Receives health data batches from the Watch → routes to ServerSync
/// - Receives challenge completion messages from the Watch → credits TIME ALIVE via GameEngine
/// - Receives audio files recorded on the Watch → feeds into AudioPipeline for processing
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            print("[PhoneSession] WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        print("[PhoneSession] WCSession activation requested")
    }

    // MARK: - Push Game State to Watch

    /// Serializes the game state and sends it to the Watch via applicationContext.
    /// applicationContext is ideal because it always delivers the latest state,
    /// even if the Watch wasn't reachable when the update was sent.
    func pushGameState(_ state: SharedGameState) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            print("[PhoneSession] Session not activated, skipping push")
            return
        }

        let context = state.toDictionary()
        do {
            try session.updateApplicationContext(context)
        } catch {
            print("[PhoneSession] Failed to push game state: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {

    // MARK: Activation

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("[PhoneSession] Activation failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        print("[PhoneSession] Activated with state: \(activationState.rawValue)")

        // Push current game state immediately so the Watch has fresh data
        let engine = GameEngine.shared
        let state = SharedGameState(
            pickupsToday: engine.pickupsToday,
            currentStreak: engine.currentStreak,
            longestStreak: engine.longestStreak,
            timeAliveSeconds: 0,
            currentTaunt: engine.currentTaunt,
            activeChallenge: engine.activeChallenge?.toChallengeTransfer(),
            screenTimeThisSession: engine.screenTimeThisSession,
            timestamp: .now
        )
        pushGameState(state)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("[PhoneSession] Session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for multi-watch switching support
        print("[PhoneSession] Session deactivated, re-activating")
        WCSession.default.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        print("[PhoneSession] Reachability changed: \(session.isReachable)")
    }

    // MARK: Receive User Info (Health Data Batches)

    /// The Watch sends health data via `transferUserInfo` so no samples are lost,
    /// even if the phone is temporarily unreachable.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let healthData = HealthDataTransfer.from(dictionary: userInfo) else {
            print("[PhoneSession] Received userInfo but could not decode HealthDataTransfer")
            return
        }

        print("[PhoneSession] Received health data batch: \(healthData.heartRateSamples.count) HR samples, \(healthData.stepCount) steps")
        ServerSync.shared.syncHealthData(healthData)
    }

    // MARK: Receive Message (Challenge Completions)

    /// The Watch sends challenge completions via `sendMessage` for real-time response.
    /// We reply with the updated game state so the Watch UI updates immediately.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let completion = ChallengeCompletionMessage.from(dictionary: message) else {
            print("[PhoneSession] Received message but could not decode ChallengeCompletionMessage")
            replyHandler(["error": "unknown_message"])
            return
        }

        print("[PhoneSession] Watch completed challenge: \(completion.challengeText)")

        DispatchQueue.main.async {
            let engine = GameEngine.shared
            engine.completeChallenge(completion: completion)

            // Reply with the updated game state
            let updatedState = SharedGameState(
                pickupsToday: engine.pickupsToday,
                currentStreak: engine.currentStreak,
                longestStreak: engine.longestStreak,
                timeAliveSeconds: 0,
                currentTaunt: engine.currentTaunt,
                activeChallenge: engine.activeChallenge?.toChallengeTransfer(),
                screenTimeThisSession: engine.screenTimeThisSession,
                timestamp: .now
            )
            replyHandler(updatedState.toDictionary())
        }
    }

    // MARK: Receive File (Watch Mic Audio)

    /// The Watch records short audio clips and transfers them via `transferFile`.
    /// We read the audio data and feed it into AudioPipeline for VAD + transcription.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let sampleRate = metadata["sampleRate"] as? Int ?? 16000
        let channels = metadata["channels"] as? Int ?? 1
        let bitsPerSample = metadata["bitsPerSample"] as? Int ?? 16
        let startTimestamp = metadata["startTime"] as? TimeInterval ?? Date.now.timeIntervalSince1970
        let endTimestamp = metadata["endTime"] as? TimeInterval ?? Date.now.timeIntervalSince1970

        guard let audioData = try? Data(contentsOf: file.fileURL) else {
            print("[PhoneSession] Failed to read Watch audio file at \(file.fileURL)")
            return
        }

        let chunk = AudioChunk(
            audioData: audioData,
            startTime: Date(timeIntervalSince1970: startTimestamp),
            endTime: Date(timeIntervalSince1970: endTimestamp),
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        print("[PhoneSession] Received Watch audio: \(audioData.count) bytes, \(String(format: "%.1f", chunk.durationSeconds))s")
        AudioPipeline.shared.processWatchAudio(chunk)
    }
}
