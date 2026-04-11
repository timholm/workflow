import Foundation
import HealthKit
import Combine

/// Collects health data from HealthKit on Apple Watch and batches it
/// for transfer to the iPhone via WatchConnectivity.
///
/// Runs anchored queries for heart rate (with background delivery) and
/// observer queries for workouts. Steps and active energy refresh on
/// a 5-minute cadence. Every 15 minutes the collector packages
/// everything into a HealthDataTransfer and hands it off to
/// WatchSessionManager for relay to the iPhone → server → printer.
final class HealthDataCollector: NSObject, ObservableObject {

    static let shared = HealthDataCollector()

    // MARK: - Published State

    @Published var latestHeartRate: Double?
    @Published var todaySteps: Int = 0
    @Published var todayActiveEnergy: Double = 0
    @Published var lastNightSleep: SleepSummary?
    @Published var todayWorkouts: Int = 0
    @Published var todayStandingHours: Int = 0

    // MARK: - HealthKit

    private let healthStore = HKHealthStore()

    /// Anchor for heart rate anchored object query — persisted across launches
    /// so we only process new samples.
    private var heartRateAnchor: HKQueryAnchor?

    /// All heart rate samples collected since the last batch flush.
    private var collectedHeartRateSamples: [HeartRateSample] = []

    /// Latest workout summaries collected since last batch flush.
    private var collectedWorkouts: [WorkoutSummary] = []

    // MARK: - Types

    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let stepCountType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    private let workoutType = HKWorkoutType.workoutType()
    private let standHourType = HKCategoryType.categoryType(forIdentifier: .appleStandHour)!

    // MARK: - Timers

    private var statsRefreshTimer: Timer?
    private var batchTimer: Timer?

    private let statsRefreshInterval: TimeInterval = 5 * 60   // 5 minutes
    private let batchInterval: TimeInterval = 15 * 60          // 15 minutes

    private var batchStart: Date = .now

    // MARK: - Init

    override private init() {
        super.init()
    }

    // MARK: - Authorization

    /// Request HealthKit authorization for all required types.
    /// Call this once from the Watch app's activation path.
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }

        let readTypes: Set<HKObjectType> = [
            heartRateType,
            stepCountType,
            activeEnergyType,
            sleepType,
            workoutType,
            standHourType,
        ]

        healthStore.requestAuthorization(toShare: nil, read: readTypes) { [weak self] success, error in
            if success {
                self?.startCollecting()
            }
            completion(success, error)
        }
    }

    // MARK: - Start Collection

    /// Kicks off all queries, timers, and background delivery.
    private func startCollecting() {
        startHeartRateQuery()
        startBackgroundDelivery()
        startWorkoutObserver()
        refreshStatistics()
        refreshSleepData()
        refreshStandingHours()
        startTimers()
    }

    // MARK: - Heart Rate (Anchored Object Query + Background Delivery)

    /// Runs an HKAnchoredObjectQuery that streams new heart rate samples
    /// as they arrive. The initial results handler also catches up on any
    /// samples recorded while the app was not running.
    private func startHeartRateQuery() {
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: heartRateAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            guard error == nil else { return }
            self?.heartRateAnchor = newAnchor
            self?.processHeartRateSamples(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            guard error == nil else { return }
            self?.heartRateAnchor = newAnchor
            self?.processHeartRateSamples(samples)
        }

        healthStore.execute(query)
    }

    /// Register for background delivery of heart rate data.
    /// watchOS will wake our extension when new samples land.
    func startBackgroundDelivery() {
        healthStore.enableBackgroundDelivery(
            for: heartRateType,
            frequency: .immediate
        ) { success, error in
            if let error = error {
                print("[HealthCollector] Background delivery registration failed: \(error)")
            }
        }
    }

    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample] else { return }

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        let newSamples: [HeartRateSample] = quantitySamples.map { sample in
            let bpm = sample.quantity.doubleValue(for: bpmUnit)
            let context = motionContext(from: sample)
            return HeartRateSample(bpm: bpm, timestamp: sample.startDate, motionContext: context)
        }

        DispatchQueue.main.async { [weak self] in
            self?.collectedHeartRateSamples.append(contentsOf: newSamples)
            self?.latestHeartRate = newSamples.last?.bpm
        }
    }

    /// Extract motion context metadata from a heart rate sample.
    private func motionContext(from sample: HKQuantitySample) -> String {
        guard let contextValue = sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber else {
            return "unknown"
        }
        switch HKHeartRateMotionContext(rawValue: contextValue.intValue) {
        case .sedentary:
            return "resting"
        case .active:
            return "active"
        default:
            return "unknown"
        }
    }

    // MARK: - Steps & Active Energy (Statistics Queries)

    /// Refresh today's cumulative step count and active energy.
    /// Called every 5 minutes by the stats timer.
    private func refreshStatistics() {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: .now, options: .strictStartDate)

        // Steps
        let stepQuery = HKStatisticsQuery(
            quantityType: stepCountType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, statistics, error in
            guard error == nil, let sum = statistics?.sumQuantity() else { return }
            let steps = Int(sum.doubleValue(for: .count()))
            DispatchQueue.main.async {
                self?.todaySteps = steps
            }
        }
        healthStore.execute(stepQuery)

        // Active Energy
        let energyQuery = HKStatisticsQuery(
            quantityType: activeEnergyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, statistics, error in
            guard error == nil, let sum = statistics?.sumQuantity() else { return }
            let kcal = sum.doubleValue(for: .kilocalorie())
            DispatchQueue.main.async {
                self?.todayActiveEnergy = kcal
            }
        }
        healthStore.execute(energyQuery)
    }

    // MARK: - Sleep Analysis

    /// Query last night's sleep. "Last night" is defined as the most recent
    /// sleep session that ended between midnight and noon today.
    private func refreshSleepData() {
        let calendar = Calendar.current
        let now = Date()

        // Look back 24 hours for the most recent sleep session
        let startLookback = calendar.date(byAdding: .hour, value: -24, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: startLookback, end: now, options: .strictEndDate)

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            guard error == nil, let categorySamples = samples as? [HKCategorySample], !categorySamples.isEmpty else {
                return
            }

            // Group into a single sleep session
            var totalSleep: TimeInterval = 0
            var deepSleep: TimeInterval = 0
            var remSleep: TimeInterval = 0
            var lightSleep: TimeInterval = 0
            var awake: TimeInterval = 0
            var earliestStart: Date = .distantFuture
            var latestEnd: Date = .distantPast

            for sample in categorySamples {
                let duration = sample.endDate.timeIntervalSince(sample.startDate)

                if sample.startDate < earliestStart { earliestStart = sample.startDate }
                if sample.endDate > latestEnd { latestEnd = sample.endDate }

                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .asleepDeep:
                    deepSleep += duration
                    totalSleep += duration
                case .asleepREM:
                    remSleep += duration
                    totalSleep += duration
                case .asleepCore:
                    lightSleep += duration
                    totalSleep += duration
                case .asleepUnspecified:
                    lightSleep += duration
                    totalSleep += duration
                case .awake:
                    awake += duration
                default:
                    break
                }
            }

            guard totalSleep > 0 else { return }

            let summary = SleepSummary(
                totalSleepSeconds: totalSleep,
                deepSleepSeconds: deepSleep,
                remSleepSeconds: remSleep,
                lightSleepSeconds: lightSleep,
                awakeSeconds: awake,
                sleepStart: earliestStart,
                sleepEnd: latestEnd
            )

            DispatchQueue.main.async {
                self?.lastNightSleep = summary
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Workouts (Observer Query)

    /// HKObserverQuery watches for new workouts. When a workout is saved
    /// we run a sample query to get the details.
    private func startWorkoutObserver() {
        let observer = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            self?.fetchTodayWorkouts()
            completionHandler()
        }
        healthStore.execute(observer)

        // Also do an initial fetch
        fetchTodayWorkouts()
    }

    private func fetchTodayWorkouts() {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: .now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            guard error == nil, let workouts = samples as? [HKWorkout] else { return }

            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let summaries: [WorkoutSummary] = workouts.map { workout in
                let avgHR = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .heartRate)!)?
                    .averageQuantity()?.doubleValue(for: bpmUnit) ?? 0

                return WorkoutSummary(
                    activityType: workout.workoutActivityType.name,
                    durationSeconds: workout.duration,
                    caloriesBurned: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                    averageHeartRate: avgHR,
                    startDate: workout.startDate,
                    endDate: workout.endDate
                )
            }

            DispatchQueue.main.async {
                self?.todayWorkouts = summaries.count
                self?.collectedWorkouts = summaries
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Standing Hours

    private func refreshStandingHours() {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: .now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let query = HKSampleQuery(
            sampleType: standHourType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            guard error == nil, let categorySamples = samples as? [HKCategorySample] else { return }

            let standCount = categorySamples.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }.count

            DispatchQueue.main.async {
                self?.todayStandingHours = standCount
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Batch Collection & Transfer

    /// Package all current readings into a single HealthDataTransfer
    /// suitable for sending to the iPhone.
    func collectBatch() -> HealthDataTransfer {
        let transfer = HealthDataTransfer(
            heartRateSamples: collectedHeartRateSamples,
            stepCount: todaySteps,
            activeEnergyBurned: todayActiveEnergy,
            sleepAnalysis: lastNightSleep,
            workoutSummary: collectedWorkouts.first,
            collectionPeriod: DateIntervalCodable(start: batchStart, end: .now)
        )
        return transfer
    }

    /// Flush the batch: build the transfer, send it, and reset accumulators.
    private func flushBatch() {
        let transfer = collectBatch()

        // Hand off to WatchSessionManager for relay to iPhone
        let sessionManager = WatchSessionManager.shared
        sessionManager.appendHeartRateSamples(collectedHeartRateSamples)
        sessionManager.updateStepCount(todaySteps)
        sessionManager.updateActiveEnergy(todayActiveEnergy)
        if let sleep = lastNightSleep {
            sessionManager.updateSleepSummary(sleep)
        }
        if let workout = collectedWorkouts.first {
            sessionManager.updateWorkoutSummary(workout)
        }
        sessionManager.sendHealthBatch()

        // Reset batch accumulators
        collectedHeartRateSamples.removeAll()
        collectedWorkouts.removeAll()
        batchStart = .now

        print("[HealthCollector] Flushed batch — \(transfer.heartRateSamples.count) HR samples, \(transfer.stepCount) steps")
    }

    // MARK: - Timers

    private func startTimers() {
        // Refresh steps/energy/standing every 5 minutes
        statsRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: statsRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshStatistics()
            self?.refreshStandingHours()
        }

        // Flush batch to iPhone every 15 minutes
        batchTimer = Timer.scheduledTimer(
            withTimeInterval: batchInterval,
            repeats: true
        ) { [weak self] _ in
            self?.flushBatch()
        }
    }

    // MARK: - Cleanup

    func invalidate() {
        statsRefreshTimer?.invalidate()
        batchTimer?.invalidate()
        statsRefreshTimer = nil
        batchTimer = nil
    }
}

// MARK: - WatchSessionManager Batch Helpers

extension WatchSessionManager {
    /// Append multiple heart rate samples at once (used by batch flush).
    func appendHeartRateSamples(_ samples: [HeartRateSample]) {
        for sample in samples {
            appendHeartRateSample(sample)
        }
    }
}

// MARK: - HKWorkoutActivityType Name Helper

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running:          return "running"
        case .cycling:          return "cycling"
        case .walking:          return "walking"
        case .swimming:         return "swimming"
        case .hiking:           return "hiking"
        case .yoga:             return "yoga"
        case .functionalStrengthTraining: return "strength"
        case .traditionalStrengthTraining: return "strength"
        case .highIntensityIntervalTraining: return "hiit"
        case .crossTraining:    return "cross_training"
        case .elliptical:       return "elliptical"
        case .rowing:           return "rowing"
        case .stairClimbing:    return "stair_climbing"
        case .pilates:          return "pilates"
        case .dance:            return "dance"
        default:                return "other"
        }
    }
}
