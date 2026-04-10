import SwiftUI

@main
struct TimVoiceApp: App {
    @StateObject private var audioManager = AudioManager.shared
    @StateObject private var voiceProfile = VoiceProfileManager.shared

    var body: some Scene {
        WindowGroup {
            if voiceProfile.isEnrolled {
                DashboardView()
                    .environmentObject(audioManager)
                    .environmentObject(voiceProfile)
            } else {
                EnrollmentView()
                    .environmentObject(voiceProfile)
            }
        }
    }
}
