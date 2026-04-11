import Foundation

/// Syncs Tim-only transcriptions to the server for AI categorization
/// and print job generation.
///
/// The server URL is configurable. Sync happens:
/// - Immediately when WiFi is available
/// - In batch when reconnecting after being offline
/// - On a 5-minute timer as a fallback
final class ServerSync: ObservableObject {
    static let shared = ServerSync()

    @Published var isSyncing = false
    @Published var lastSyncTime: Date?

    /// Configure this to point to your server
    var serverBaseURL = "http://localhost:8080"

    private var syncQueue: [TranscriptionSegment] = []
    private let syncInterval: TimeInterval = 300 // 5 minutes
    private var syncTimer: Timer?
    private let store = TranscriptionStore.shared

    private init() {
        startSyncTimer()
    }

    func queueForSync(_ segment: TranscriptionSegment) {
        syncQueue.append(segment)

        // Try immediate sync if queue is building up
        if syncQueue.count >= 5 {
            performSync()
        }
    }

    // MARK: - Sync Execution

    func performSync() {
        guard !isSyncing, !syncQueue.isEmpty else { return }

        DispatchQueue.main.async { self.isSyncing = true }

        let batch = Array(syncQueue.prefix(50)) // max 50 per request
        let payload = SyncPayload(segments: batch, deviceId: deviceId())

        guard let url = URL(string: "\(serverBaseURL)/api/ingest"),
              let body = try? JSONEncoder().encode(payload) else {
            DispatchQueue.main.async { self.isSyncing = false }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Mark as synced
                for segment in batch {
                    self.store.markSynced(id: segment.id)
                }
                self.syncQueue.removeFirst(min(batch.count, self.syncQueue.count))

                DispatchQueue.main.async {
                    self.lastSyncTime = .now
                    self.isSyncing = false
                }

                print("[Sync] Synced \(batch.count) segments")
            } else {
                print("[Sync] Failed: \(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
                DispatchQueue.main.async { self.isSyncing = false }
            }
        }.resume()
    }

    // MARK: - Timer

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            // Also pick up any unsynced segments from the store
            if let unsynced = self?.store.unsyncedSegments() {
                for segment in unsynced {
                    if !(self?.syncQueue.contains(where: { $0.id == segment.id }) ?? true) {
                        self?.syncQueue.append(segment)
                    }
                }
            }
            self?.performSync()
        }
    }

    // MARK: - Health Data Sync (from Watch)

    /// Posts a batch of health data received from the Watch to the server
    /// for inclusion in printed morning/afternoon briefs.
    func syncHealthData(_ data: HealthDataTransfer) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let url = URL(string: "\(serverBaseURL)/api/ingest/health"),
              let body = try? encoder.encode(data) else {
            print("[Sync] Failed to encode health data")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[Sync] Health data synced successfully")
            } else {
                print("[Sync] Health sync failed: \(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
            }
        }.resume()
    }

    // MARK: - Game Stats Sync

    /// Posts the current game state to the server so it can be included
    /// in printed briefs (pickups, streaks, TIME ALIVE, etc.).
    func syncGameStats(_ state: SharedGameState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        struct GameStatsPayload: Codable {
            let gameState: SharedGameState
            let deviceId: String
        }

        let payload = GameStatsPayload(gameState: state, deviceId: deviceId())
        guard let url = URL(string: "\(serverBaseURL)/api/ingest/game"),
              let body = try? encoder.encode(payload) else {
            print("[Sync] Failed to encode game stats")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[Sync] Game stats synced successfully")
            } else {
                print("[Sync] Game stats sync failed: \(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
            }
        }.resume()
    }

    // MARK: - Device ID

    private let sharedDefaults = UserDefaults(suiteName: "group.community.holm.timvoice")!

    private func deviceId() -> String {
        let key = "com.timvoice.deviceId"
        if let existing = sharedDefaults.string(forKey: key) {
            return existing
        }
        // Migrate from standard defaults if present
        if let legacy = UserDefaults.standard.string(forKey: key) {
            sharedDefaults.set(legacy, forKey: key)
            return legacy
        }
        let id = UUID().uuidString
        sharedDefaults.set(id, forKey: key)
        return id
    }
}

struct SyncPayload: Codable {
    let segments: [TranscriptionSegment]
    let deviceId: String
}
