import SwiftUI
import HealthKit
import WatchKit

// MARK: - Health Data Store

/// Caches the latest health readings from HealthKit.
/// Runs on the Watch — queries are local to the wrist sensor data.
final class HealthDataStore: ObservableObject {
    static let shared = HealthDataStore()

    @Published var stepCount: Int = 0
    @Published var heartRate: Double = 0
    @Published var heartRateTimestamp: Date?
    @Published var activeEnergyBurned: Double = 0
    @Published var sleepHours: Double = 0
    @Published var sleepQuality: SleepQuality = .unknown
    @Published var workoutCountToday: Int = 0

    private let healthStore = HKHealthStore()
    private var heartRateQuery: HKAnchoredObjectQuery?

    enum SleepQuality: String {
        case unknown = "?"
        case poor = "POOR"
        case fair = "FAIR"
        case good = "GOOD"
        case great = "GREAT"
    }

    private init() {}

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }

        let readTypes: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKQuantityType.workoutType(),
        ]

        healthStore.requestAuthorization(toShare: nil, read: readTypes) { granted, error in
            DispatchQueue.main.async {
                completion(granted && error == nil)
            }
        }
    }

    // MARK: - Refresh All

    func refreshAll() {
        fetchStepCount()
        fetchHeartRate()
        fetchActiveEnergy()
        fetchSleep()
        fetchWorkoutCount()
    }

    // MARK: - Steps

    private func fetchStepCount() {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let predicate = todayPredicate()

        let query = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, result, _ in
            let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            DispatchQueue.main.async {
                self.stepCount = Int(steps)
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Heart Rate

    private func fetchHeartRate() {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: type,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sort]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            DispatchQueue.main.async {
                self.heartRate = bpm
                self.heartRateTimestamp = sample.endDate
            }
        }
        healthStore.execute(query)
    }

    /// Start continuous heart rate observation.
    func startHeartRateObservation() {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: HKQuery.predicateForSamples(
                withStart: Date(),
                end: nil,
                options: .strictStartDate
            ),
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.handleHeartRateSamples(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handleHeartRateSamples(samples)
        }

        heartRateQuery = query
        healthStore.execute(query)
    }

    func stopHeartRateObservation() {
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
    }

    private func handleHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample],
              let latest = quantitySamples.last else { return }
        let bpm = latest.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async {
            self.heartRate = bpm
            self.heartRateTimestamp = latest.endDate
        }
    }

    // MARK: - Active Energy

    private func fetchActiveEnergy() {
        let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let predicate = todayPredicate()

        let query = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, result, _ in
            let kcal = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            DispatchQueue.main.async {
                self.activeEnergyBurned = kcal
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Sleep

    private func fetchSleep() {
        let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!

        // Look at last night: 8pm yesterday to 12pm today
        let calendar = Calendar.current
        let now = Date()
        let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: -16, to: todayNoon)!

        let predicate = HKQuery.predicateForSamples(
            withStart: yesterdayEvening,
            end: todayNoon,
            options: .strictStartDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let query = HKSampleQuery(
            sampleType: type,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { _, samples, _ in
            guard let categorySamples = samples as? [HKCategorySample] else { return }

            // Sum up asleep intervals (InBed + Asleep stages)
            var totalSleepSeconds: TimeInterval = 0
            for sample in categorySamples {
                let value = HKCategoryValueSleepAnalysis(rawValue: sample.value)
                switch value {
                case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified:
                    totalSleepSeconds += sample.endDate.timeIntervalSince(sample.startDate)
                default:
                    break
                }
            }

            let hours = totalSleepSeconds / 3600.0
            let quality: SleepQuality
            switch hours {
            case ..<4:    quality = .poor
            case 4..<6:   quality = .fair
            case 6..<7.5: quality = .good
            default:       quality = .great
            }

            DispatchQueue.main.async {
                self.sleepHours = hours
                self.sleepQuality = quality
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Workouts

    private func fetchWorkoutCount() {
        let type = HKQuantityType.workoutType()
        let predicate = todayPredicate()

        let query = HKSampleQuery(
            sampleType: type,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, samples, _ in
            DispatchQueue.main.async {
                self.workoutCountToday = samples?.count ?? 0
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Helpers

    private func todayPredicate() -> NSPredicate {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: nil,
            options: .strictStartDate
        )
    }
}

// MARK: - Health Transfer (for Watch <-> Phone)

struct HealthDataTransfer: Codable {
    var heartRateSamples: [HeartRateSample]
    var stepCount: Int
    var activeEnergyBurned: Double
    var sleepAnalysis: SleepSummary?
    var workoutSummary: [WorkoutEntry]

    struct HeartRateSample: Codable {
        let bpm: Double
        let timestamp: Date
    }

    struct SleepSummary: Codable {
        let totalHours: Double
        let quality: String
    }

    struct WorkoutEntry: Codable {
        let type: String
        let durationMinutes: Double
        let caloriesBurned: Double
    }
}

// MARK: - Watch Health View

/// Health dashboard for the Watch. Compact, monospaced, no fluff.
/// Accessible as a tab swipe from the main game face.
struct WatchHealthView: View {
    @StateObject private var store = HealthDataStore.shared

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
        .onAppear {
            store.requestAuthorization { granted in
                if granted { store.refreshAll() }
            }
            store.startHeartRateObservation()
        }
        .onDisappear {
            store.stopHeartRateObservation()
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

                // Count
                VStack(spacing: 0) {
                    Text("\(store.stepCount)")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("/ \(formatNumber(stepGoal))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if store.stepCount >= stepGoal {
                Text("GOAL HIT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
    }

    private var stepProgress: Double {
        guard stepGoal > 0 else { return 0 }
        return Double(store.stepCount) / Double(stepGoal)
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
                    Text(store.heartRate > 0 ? "\(Int(store.heartRate))" : "--")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("BPM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()

            if let ts = store.heartRateTimestamp {
                Text(relativeTimeString(from: ts))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
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
                    Text("\(Int(store.activeEnergyBurned))")
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

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", store.sleepHours))
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("HRS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()

            Text(store.sleepQuality.rawValue)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(sleepQualityColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sleepQualityColor.opacity(0.2))
                .cornerRadius(4)
        }
    }

    private var sleepQualityColor: Color {
        switch store.sleepQuality {
        case .unknown: return .gray
        case .poor:    return .red
        case .fair:    return .orange
        case .good:    return .yellow
        case .great:   return .green
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
                Text("\(store.workoutCountToday)")
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
