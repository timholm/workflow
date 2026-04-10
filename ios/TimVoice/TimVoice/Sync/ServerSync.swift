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

    // MARK: - Device ID

    private func deviceId() -> String {
        let key = "com.timvoice.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

struct SyncPayload: Codable {
    let segments: [TranscriptionSegment]
    let deviceId: String
}
