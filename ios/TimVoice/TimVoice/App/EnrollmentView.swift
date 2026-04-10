import SwiftUI

struct EnrollmentView: View {
    @EnvironmentObject var voiceProfile: VoiceProfileManager
    @State private var currentStep = 0
    @State private var isRecordingSample = false

    private let prompts = [
        "Read aloud: \"I'm setting up my voice so only my words get captured.\"",
        "Read aloud: \"The morning print will have my schedule, tasks, and anything I said overnight.\"",
        "Read aloud: \"This is my voice. The system should recognize me and only me.\"",
        "Now just talk naturally for 30 seconds. Say anything — describe your day, what you're thinking about.",
        "One more — count from one to twenty at your normal speaking pace."
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Progress
                ProgressView(value: Double(currentStep), total: Double(prompts.count))
                    .padding(.horizontal)

                Text("Voice Enrollment")
                    .font(.title2.bold())

                Text("Step \(currentStep + 1) of \(prompts.count)")
                    .foregroundColor(.secondary)

                // Prompt card
                Text(prompts[currentStep])
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                Spacer()

                // Record button
                Button(action: { handleRecordTap() }) {
                    ZStack {
                        Circle()
                            .fill(isRecordingSample ? Color.red : Color.blue)
                            .frame(width: 80, height: 80)

                        if isRecordingSample {
                            Circle()
                                .stroke(Color.red, lineWidth: 3)
                                .frame(width: 96, height: 96)
                                .scaleEffect(isRecordingSample ? 1.2 : 1.0)
                                .opacity(isRecordingSample ? 0 : 1)
                                .animation(.easeInOut(duration: 1).repeatForever(), value: isRecordingSample)
                        }

                        Image(systemName: isRecordingSample ? "stop.fill" : "mic.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                }

                Text(isRecordingSample ? "Tap to stop" : "Tap to record")
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleRecordTap() {
        if isRecordingSample {
            // Stop recording this sample
            isRecordingSample = false
            voiceProfile.finishEnrollmentSample(step: currentStep)

            if currentStep < prompts.count - 1 {
                currentStep += 1
            } else {
                voiceProfile.finalizeEnrollment()
            }
        } else {
            isRecordingSample = true
            voiceProfile.startEnrollmentSample(step: currentStep)
        }
    }
}
