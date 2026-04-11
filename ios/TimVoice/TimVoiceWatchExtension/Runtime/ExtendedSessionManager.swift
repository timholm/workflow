import WatchKit
import Combine

/// Manages WKExtendedRuntimeSession to keep the Watch app alive for
/// background mic recording, heart rate monitoring, and mindfulness timers.
///
/// watchOS kills background apps aggressively. Extended runtime sessions
/// buy us extra time — the system will eventually expire them, but we
/// automatically request a new session when the current one ends if the
/// need persists (e.g., phone is still far away and we're still recording).
///
/// Session type: `.selfCare` — intended for mindfulness and self-care apps,
/// which is exactly what TimVoice is. Tim taking care of himself by not
/// using his phone.
final class ExtendedSessionManager: NSObject, ObservableObject {
    static let shared = ExtendedSessionManager()

    // MARK: - Published State

    /// True when there is an active (running) extended runtime session.
    @Published var hasActiveSession = false

    // MARK: - Internal

    private var currentSession: WKExtendedRuntimeSession?

    /// Tracks why a session is needed so we can decide whether to restart
    /// after expiration.
    private var activeReasons: Set<SessionReason> = []

    /// Callback fired when a session expires. Consumers (WatchMicRecorder,
    /// health monitor) can react to the brief gap before a new session starts.
    var onSessionExpiring: (() -> Void)?

    /// Callback fired when a new session becomes active after renewal.
    var onSessionRenewed: (() -> Void)?

    // MARK: - Init

    override private init() {
        super.init()
    }

    // MARK: - Session Lifecycle

    /// Request an extended runtime session for the given reason.
    /// If a session is already running, just records the reason so the
    /// session won't be torn down prematurely.
    func requestSession(for reason: SessionReason) {
        activeReasons.insert(reason)

        guard currentSession == nil || currentSession?.state == .invalid else {
            // Session already running — nothing else to do.
            return
        }

        startNewSession()
    }

    /// Release a session reason. If no reasons remain, the session is invalidated.
    func releaseSession(for reason: SessionReason) {
        activeReasons.remove(reason)

        if activeReasons.isEmpty {
            invalidateCurrentSession()
        }
    }

    /// Invalidate the current session immediately regardless of remaining reasons.
    func invalidateAll() {
        activeReasons.removeAll()
        invalidateCurrentSession()
    }

    // MARK: - Internal Session Management

    private func startNewSession() {
        // Invalidate any stale session before creating a new one
        if let existing = currentSession, existing.state != .invalid {
            existing.invalidate()
        }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        currentSession = session

        print("[ExtendedSessionManager] Starting new session for reasons: \(activeReasons)")
    }

    private func invalidateCurrentSession() {
        guard let session = currentSession, session.state != .invalid else {
            hasActiveSession = false
            return
        }

        session.invalidate()
        currentSession = nil
        hasActiveSession = false

        print("[ExtendedSessionManager] Session invalidated — no active reasons remain")
    }

    /// Called when the system is about to expire the session or after it has
    /// been invalidated. If reasons still exist, we immediately request a new one.
    private func handleSessionEnd() {
        hasActiveSession = false
        currentSession = nil

        if !activeReasons.isEmpty {
            // Still need a session — request a new one after a brief pause
            // to avoid hammering the system.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.activeReasons.isEmpty else { return }
                self.startNewSession()
                self.onSessionRenewed?()
            }
            print("[ExtendedSessionManager] Session ended but reasons remain — will renew: \(activeReasons)")
        } else {
            print("[ExtendedSessionManager] Session ended — no renewal needed")
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension ExtendedSessionManager: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { [weak self] in
            self?.hasActiveSession = true
        }
        print("[ExtendedSessionManager] Session started")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // The system is about to kill our session. Notify consumers so they
        // can flush buffers, save state, etc.
        onSessionExpiring?()
        print("[ExtendedSessionManager] Session will expire — flushing state")
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        if let error {
            print("[ExtendedSessionManager] Session invalidated with error: \(error)")
        } else {
            print("[ExtendedSessionManager] Session invalidated — reason: \(reason.rawValue)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleSessionEnd()
        }
    }
}

// MARK: - Session Reasons

/// Why we need an extended runtime session. Multiple reasons can be active
/// simultaneously — the session stays alive until all are released.
enum SessionReason: Hashable, CustomStringConvertible {
    /// iPhone is unreachable and we're recording audio from the Watch mic.
    case micRecording

    /// Heart rate monitoring is active during a physical challenge.
    case heartRateMonitoring

    /// A mindfulness challenge timer is counting down.
    case mindfulnessTimer

    var description: String {
        switch self {
        case .micRecording:       return "mic_recording"
        case .heartRateMonitoring: return "heart_rate_monitoring"
        case .mindfulnessTimer:   return "mindfulness_timer"
        }
    }
}
