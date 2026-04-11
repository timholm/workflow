import SwiftUI
import HealthKit
import WatchKit

/// Health dashboard for the Watch. Compact, monospaced, no fluff.
/// Accessible as a tab swipe from the main game face.
///
/// Pulls from the existing HealthDataCollector which runs anchored
/// queries and caches readings on the Watch.
struct WatchHealthView: View {
    @EnvironmentObject var healthCollector: HealthDataCollector

    private let stepGoal: Int = 10_000

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Steps with progress ring
                stepsSection

                Divider().background(Color.white.opacity(0.2))

                // Heart rate
                heartRateSection

                Divider().background(Color.white.opacity(0.2))

                // Active energy
                energySection

                Divider().background(Color.white.opacity(0.2))

                // Sleep
                sleepSection

                Divider().background(Color.white.opacity(0.2))

                // Workouts
                workoutSection
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(spacing: 6) {
            Text("STEPS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                    .frame(width: 70, height: 70)

                // Progress ring
                Circle()
                    .trim(from: 0, to: min(stepProgress, 1.0))
                    .stroke(stepProgressColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: stepProgress)

                // Count
                VStack(spacing: 0) {
                    Text("\(healthCollector.todaySteps)")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("/ \(formatCompact(stepGoal))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if healthCollector.todaySteps >= stepGoal {
                Text("GOAL HIT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
    }

    private var stepProgress: Double {
        guard stepGoal > 0 else { return 0 }
        return Double(healthCollector.todaySteps) / Double(stepGoal)
    }

    private var stepProgressColor: Color {
        if stepProgress >= 1.0 { return .green }
        if stepProgress >= 0.5 { return .yellow }
        return .orange
    }

    // MARK: - Heart Rate

    private var heartRateSection: some View {
        HStack {
            Image(systemName: "heart.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("HEART RATE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let bpm = healthCollector.latestHeartRate {
                        Text("\(Int(bpm))")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                    } else {
                        Text("--")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Text("BPM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()
        }
    }

    // MARK: - Energy

    private var energySection: some View {
        HStack {
            Image(systemName: "flame.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("ACTIVE ENERGY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(healthCollector.todayActiveEnergy))")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("KCAL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()
        }
    }

    // MARK: - Sleep

    private var sleepSection: some View {
        HStack {
            Image(systemName: "moon.fill")
                .foregroundColor(.indigo)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("LAST NIGHT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                if let sleep = healthCollector.lastNightSleep {
                    let hours = sleep.totalSleepSeconds / 3600.0
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", hours))
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        Text("HRS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                } else {
                    Text("--")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            if let sleep = healthCollector.lastNightSleep {
                let quality = sleepQuality(from: sleep)
                Text(quality.label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(quality.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(quality.color.opacity(0.2))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - Workouts

    private var workoutSection: some View {
        HStack {
            Image(systemName: "figure.run")
                .foregroundColor(.green)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("WORKOUTS TODAY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text("\(healthCollector.todayWorkouts)")
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func formatCompact(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private struct SleepQualityIndicator {
        let label: String
        let color: Color
    }

    private func sleepQuality(from sleep: SleepSummary) -> SleepQualityIndicator {
        let hours = sleep.totalSleepSeconds / 3600.0
        let deepRatio = sleep.totalSleepSeconds > 0
            ? sleep.deepSleepSeconds / sleep.totalSleepSeconds
            : 0

        // Quality is based on total hours and deep sleep ratio
        switch hours {
        case ..<4:
            return SleepQualityIndicator(label: "POOR", color: .red)
        case 4..<6:
            return SleepQualityIndicator(label: "FAIR", color: .orange)
        case 6..<7.5:
            return deepRatio > 0.15
                ? SleepQualityIndicator(label: "GOOD", color: .yellow)
                : SleepQualityIndicator(label: "FAIR", color: .orange)
        default:
            return deepRatio > 0.15
                ? SleepQualityIndicator(label: "GREAT", color: .green)
                : SleepQualityIndicator(label: "GOOD", color: .yellow)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct WatchHealthView_Previews: PreviewProvider {
    static var previews: some View {
        WatchHealthView()
            .environmentObject(HealthDataCollector.shared)
    }
}
#endif
