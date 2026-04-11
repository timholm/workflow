import SwiftUI

@main
struct TimVoiceApp: App {
    @StateObject private var audioManager = AudioManager.shared
    @StateObject private var voiceProfile = VoiceProfileManager.shared
    @StateObject private var game = GameEngine.shared

    var body: some Scene {
        WindowGroup {
            if !voiceProfile.isEnrolled {
                // First launch only — enroll voice, then never see this again
                EnrollmentView()
                    .environmentObject(voiceProfile)
            } else {
                // THE GAME. This is all you see. Every time.
                GameView()
                    .environmentObject(audioManager)
                    .environmentObject(voiceProfile)
                    .environmentObject(game)
                    .onAppear {
                        // Start recording silently — the game is the only UI
                        audioManager.startRecording()
                        AudioPipeline.shared.start()
                        CameraManager.shared.startCapture()
                    }
            }
        }
    }
}
