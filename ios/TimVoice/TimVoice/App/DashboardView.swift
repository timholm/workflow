import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var audioManager: AudioManager
    @StateObject private var pipeline = AudioPipeline.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                // Status indicator
                Circle()
                    .fill(audioManager.isRecording ? Color.green : Color.red)
                    .frame(width: 120, height: 120)
                    .overlay(
                        Text(audioManager.isRecording ? "LIVE" : "OFF")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    )
                    .shadow(color: audioManager.isRecording ? .green.opacity(0.5) : .clear, radius: 20)

                // Stats
                VStack(spacing: 12) {
                    StatRow(label: "Today's segments", value: "\(pipeline.todaySegmentCount)")
                    StatRow(label: "Words captured", value: "\(pipeline.todayWordCount)")
                    StatRow(label: "Pending sync", value: "\(pipeline.pendingSyncCount)")
                    StatRow(label: "Uptime", value: pipeline.uptimeString)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                Spacer()

                // Main toggle
                Button(action: { toggleRecording() }) {
                    Text(audioManager.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(audioManager.isRecording ? Color.red : Color.green)
                        .cornerRadius(12)
                }
            }
            .padding(24)
            .navigationTitle("TimVoice")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func toggleRecording() {
        if audioManager.isRecording {
            audioManager.stopRecording()
        } else {
            audioManager.startRecording()
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .bold()
        }
    }
}
