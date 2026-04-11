import SwiftUI
import WatchKit
import HealthKit

/// Full-screen challenge view. Shows the dare, the reward, and
/// the tools to prove you did it (heart rate for physical,
/// countdown for mindful). No decoration. Just the work.
struct WatchChallengeView: View {
    @EnvironmentObject var engine: WatchGameEngine

    @State private var completed = false
    @State private var skipped = false
    @State private var mindfulSecondsRemaining: Int = 0
    @State private var mindfulTimerActive = false
    @State private var mindfulTimerFinished = false
    @State private var heartRate: Double = 0
    @State private var heartRateQuery: HKAnchoredObjectQuery?

    private let healthStore = HKHealthStore()
    private let mindfulDuration: Int = 300 // 5 minutes

    var body: some View {
        Group {
            if completed {
                completionView
            } else if let challenge = engine.activeChallenge {
                challengeContent(challenge)
            } else {
                noChallengeView
            }
        }
    }

    // MARK: - Challenge Content

    @ViewBuilder
    private func challengeContent(_ challenge: ChallengeTransfer) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                // Challenge type badge
                Text(badgeText(for: challenge.type))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(badgeColor(for: challenge.type))
                    .padding(.top, 4)

                // The challenge text — big, unavoidable
                Text(challenge.text)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)

                // Reward
                Text(challenge.reward)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.vertical, 4)

                // Type-specific tools
                if challenge.type == "physical" {
                    physicalOverlay
                } else if challenge.type == "mindful" {
                    mindfulOverlay
                }

                Spacer(minLength: 8)

                // I DID IT
                Button(action: completeChallenge) {
                    Text("I DID IT")
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // SKIP — with shame
                Button(action: skipChallenge) {
                    VStack(spacing: 2) {
                        Text("skip")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                        Text("(skipping costs you)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.red.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Physical: Heart Rate

    private var physicalOverlay: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                Text(heartRate > 0 ? "\(Int(heartRate))" : "--")
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                    .foregroundColor(.red)
                Text("BPM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.red.opacity(0.6))
            }
            Text(heartRateVerdict)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 6)
        .onAppear { startHeartRateStream() }
        .onDisappear { stopHeartRateStream() }
    }

    private var heartRateVerdict: String {
        if heartRate <= 0 { return "waiting for sensor..." }
        if heartRate > 120 { return "effort detected. good." }
        if heartRate > 90 { return "warming up..." }
        return "you haven't started yet."
    }

    // MARK: - Mindful: Countdown

    private var mindfulOverlay: some View {
        VStack(spacing: 6) {
            Text(mindfulTimerString)
                .font(.system(size: 32, weight: .black, design: .monospaced))
                .foregroundColor(mindfulSecondsRemaining > 0 ? .cyan : .green)

            if !mindfulTimerActive && !mindfulTimerFinished {
                Button(action: startMindfulTimer) {
                    Text("START TIMER")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.cyan)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else if mindfulTimerActive {
                Text("be still.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            } else if mindfulTimerFinished {
                Text("done. you survived stillness.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 6)
    }

    private var mindfulTimerString: String {
        let m = mindfulSecondsRemaining / 60
        let s = mindfulSecondsRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("DONE.")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(.green)
            Text("that's what alive feels like.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
        }
    }

    private var noChallengeView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("NO CHALLENGE")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Text("stay off the phone\nand one will come.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Actions

    private func completeChallenge() {
        engine.completeChallenge()
        completed = true
        stopHeartRateStream()

        // Celebration haptics — three rapid success pulses
        let device = WKInterfaceDevice.current()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
                device.play(.success)
            }
        }
    }

    private func skipChallenge() {
        engine.skipChallenge()
        skipped = true

        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - Heart Rate Streaming

    private func startHeartRateStream() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!

        healthStore.requestAuthorization(toShare: nil, read: [heartRateType]) { granted, _ in
            guard granted else { return }
            self.observeHeartRate(type: heartRateType)
        }
    }

    private func observeHeartRate(type: HKQuantityType) {
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: HKQuery.predicateForSamples(
                withStart: Date(),
                end: nil,
                options: .strictStartDate
            ),
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { _, samples, _, _, _ in
            self.processHeartRateSamples(samples)
        }

        query.updateHandler = { _, samples, _, _, _ in
            self.processHeartRateSamples(samples)
        }

        heartRateQuery = query
        healthStore.execute(query)
    }

    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample],
              let latest = quantitySamples.last else { return }

        let bpm = latest.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async {
            self.heartRate = bpm
        }
    }

    private func stopHeartRateStream() {
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
    }

    // MARK: - Mindful Timer

    private func startMindfulTimer() {
        mindfulSecondsRemaining = mindfulDuration
        mindfulTimerActive = true

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if self.mindfulSecondsRemaining > 0 {
                self.mindfulSecondsRemaining -= 1
            } else {
                timer.invalidate()
                self.mindfulTimerActive = false
                self.mindfulTimerFinished = true
                WKInterfaceDevice.current().play(.success)
            }
        }
    }

    // MARK: - Helpers

    private func badgeText(for type: String) -> String {
        return "[ \(type.uppercased()) ]"
    }

    private func badgeColor(for type: String) -> Color {
        switch type {
        case "physical":  return .red
        case "social":    return .blue
        case "creative":  return .purple
        case "mindful":   return .cyan
        case "adventure": return .orange
        default:          return .gray
        }
    }
}

// MARK: - WatchGameEngine Skip Extension

extension WatchGameEngine {
    /// Called when Tim skips a challenge on the Watch.
    /// No reward. No celebration. Just quiet disappointment.
    func skipChallenge() {
        guard activeChallenge != nil else { return }

        let device = WKInterfaceDevice.current()
        device.play(.failure)

        encouragement = "Skipped. The phone wins this round."
        activeChallenge = nil
    }
}
