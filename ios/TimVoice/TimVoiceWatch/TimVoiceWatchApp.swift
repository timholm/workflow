import SwiftUI

/// The Ally. The Watch is on Tim's side.
///
/// While the phone punishes every pickup, the Watch rewards every moment
/// away from it. Green gradients instead of red. Encouragement instead
/// of taunts. Success haptics instead of warnings.
///
/// The Watch doesn't need much UI. It's a quiet companion that celebrates
/// freedom from the phone. When the phone is far away, it's happiest.
@main
struct TimVoiceWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var gameEngine = WatchGameEngine.shared

    var body: some Scene {
        WindowGroup {
            WatchGameFaceView()
                .environmentObject(sessionManager)
                .environmentObject(gameEngine)
                .onAppear {
                    sessionManager.activateSession()
                    gameEngine.startHealthCollection()
                }
        }
    }
}
