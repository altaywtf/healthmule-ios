@preconcurrency import HealthKit
import Foundation
import HealthMuleCore

protocol ConfigurableDailyRecordProvider: DailyRecordProvider, Actor {
    func configure(
        earliestVO2Date: Date,
        enabledMetrics: Set<HealthMetric>
    )
}

actor HealthKitDailyRecordProvider: ConfigurableDailyRecordProvider {
    private struct Configuration: Sendable {
        let earliestVO2Date: Date
        let enabledMetrics: Set<HealthMetric>
    }

    let healthKit: HealthKitClient
    private var configuration: Configuration?

    init(healthKit: HealthKitClient) {
        self.healthKit = healthKit
    }

    func configure(
        earliestVO2Date: Date,
        enabledMetrics: Set<HealthMetric>
    ) {
        configuration = Configuration(
            earliestVO2Date: earliestVO2Date,
            enabledMetrics: enabledMetrics
        )
    }

    func record(for date: LocalDate) async throws -> DailyHealthRecord {
        guard let configuration else {
            throw HealthKitClientError.queryFailed
        }
        return try await healthKit.dailyRecord(
            for: date,
            earliestVO2Date: configuration.earliestVO2Date,
            enabledMetrics: configuration.enabledMetrics
        )
    }
}

extension HealthKitClient {
    func dailyRecord(
        for date: LocalDate,
        earliestVO2Date: Date,
        enabledMetrics: Set<HealthMetric>
    ) async throws -> DailyHealthRecord {
        guard isAvailable else {
            throw HealthKitClientError.unavailable
        }
        let boundary = try dayBoundaryStore.boundary(
            for: date,
            currentTimeZone: .current
        )
        guard let timeZone = TimeZone(identifier: boundary.timeZoneIdentifier) else {
            throw SchemaValidationError.invalidTimeZone(boundary.timeZoneIdentifier)
        }
        async let weight = quantitySamples(
            enabled: enabledMetrics.contains(.bodyMass),
            identifier: .bodyMass,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .gramUnit(with: .kilo)
        )
        async let steps = cumulativeValue(
            enabled: enabledMetrics.contains(.stepCount),
            identifier: .stepCount,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .count()
        )
        async let activeEnergy = cumulativeValue(
            enabled: enabledMetrics.contains(.activeEnergy),
            identifier: .activeEnergyBurned,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .kilocalorie()
        )
        async let restingEnergy = cumulativeValue(
            enabled: enabledMetrics.contains(.restingEnergy),
            identifier: .basalEnergyBurned,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .kilocalorie()
        )
        async let restingHeartRate = quantitySamples(
            enabled: enabledMetrics.contains(.restingHeartRate),
            identifier: .restingHeartRate,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .count().unitDivided(by: .minute())
        )
        async let hrv = quantitySamples(
            enabled: enabledMetrics.contains(.hrvSDNN),
            identifier: .heartRateVariabilitySDNN,
            start: boundary.start,
            end: boundary.end,
            options: [.strictStartDate],
            unit: .secondUnit(with: .milli)
        )
        async let vo2Max = quantitySamples(
            enabled: enabledMetrics.contains(.vo2Max)
                && earliestVO2Date < boundary.end,
            identifier: .vo2Max,
            // R4 bounds carry-forward to the selected export history window.
            start: earliestVO2Date,
            end: boundary.end,
            options: [.strictEndDate],
            unit: HKUnit(from: "ml/kg*min")
        )
        async let sleep = sleepSamples(
            enabled: enabledMetrics.contains(.sleep),
            boundary: boundary
        )
        async let workouts = workoutSamples(
            enabled: enabledMetrics.contains(.workouts),
            boundary: boundary
        )
        async let sourceSamples = sourceSamples(
            enabledMetrics: enabledMetrics,
            start: boundary.start,
            end: boundary.end
        )

        let (
            weightSamples,
            stepValue,
            activeEnergyValue,
            restingEnergyValue,
            restingHeartRateSamples,
            hrvSamples,
            vo2Samples,
            sleepResult,
            workoutResult,
            allSourceSamples
        ) = try await (
            weight,
            steps,
            activeEnergy,
            restingEnergy,
            restingHeartRate,
            hrv,
            vo2Max,
            sleep,
            workouts,
            sourceSamples
        )

        var selectedSourceSamples: [HKSample] = sleepResult.rawSamples
            + workoutResult.rawSamples
        if let selectedVO2Sample = vo2Samples.rawSamples.max(by: {
            if $0.endDate != $1.endDate {
                return $0.endDate < $1.endDate
            }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }) {
            selectedSourceSamples.append(selectedVO2Sample)
        }
        let sourceObjectsByID = HealthSourceProvenance.uniqueSamples(
            directSamples: allSourceSamples,
            reusedQuantitySamples: HealthSourceProvenance.reusedQuantitySamples(
                enabledMetrics: enabledMetrics,
                bodyMass: weightSamples.rawSamples,
                restingHeartRate: restingHeartRateSamples.rawSamples,
                hrv: hrvSamples.rawSamples
            ),
            selectedSamples: selectedSourceSamples
        )
        let sourceNames = sourceObjectsByID.values.compactMap(\.device?.name)

        let input = DailyAggregationInput(
            date: date,
            timeZoneIdentifier: timeZone.identifier,
            weightSamples: weightSamples.values,
            steps: stepValue.map { Int($0.rounded()) },
            activeEnergyKcal: activeEnergyValue,
            restingEnergyKcal: restingEnergyValue,
            restingHeartRateSamples: restingHeartRateSamples.values,
            hrvSamples: hrvSamples.values,
            vo2MaxSamples: vo2Samples.values,
            sleepSamples: sleepResult.values.isEmpty ? nil : sleepResult.values,
            workouts: workoutResult.values,
            sourceDeviceNames: sourceNames,
            sampleCount: sourceObjectsByID.count
        )
        return try DailyHealthRecordAggregator.aggregate(input, generatedAt: .now)
    }
}

private extension HealthKitClient {
    struct QuantityResult {
        let values: [TimedQuantitySample]
        let rawSamples: [HKQuantitySample]
    }

    struct SleepResult {
        let values: [SleepSample]
        let rawSamples: [HKCategorySample]
    }

    struct WorkoutResult {
        let values: [WorkoutSample]
        let rawSamples: [HKWorkout]
    }

    func cumulativeValue(
        enabled: Bool,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        options: HKQueryOptions,
        unit: HKUnit
    ) async throws -> Double? {
        guard enabled else { return nil }
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitClientError.queryFailed
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: options
        )
        return try await executeCancellableQuery { resume in
            HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum]
            ) { _, statistics, error in
                do {
                    let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                    resume.resume(
                        returning: try HealthKitCumulativeResult.resolve(
                            value,
                            error: error
                        )
                    )
                } catch {
                    resume.resume(throwing: error)
                }
            }
        }
    }

    func quantitySamples(
        enabled: Bool,
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        options: HKQueryOptions,
        unit: HKUnit
    ) async throws -> QuantityResult {
        guard enabled else {
            return QuantityResult(values: [], rawSamples: [])
        }
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitClientError.queryFailed
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: options
        )
        let samples: [HKQuantitySample] = try await samples(
            type: type,
            predicate: predicate
        )
        return QuantityResult(
            values: samples.map {
                TimedQuantitySample(
                    id: $0.uuid.uuidString,
                    measuredAt: $0.endDate,
                    value: $0.quantity.doubleValue(for: unit)
                )
            },
            rawSamples: samples
        )
    }

    func sleepSamples(
        enabled: Bool,
        boundary: StoredDayBoundary
    ) async throws -> SleepResult {
        guard enabled else {
            return SleepResult(values: [], rawSamples: [])
        }
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitClientError.queryFailed
        }
        let queryStart = boundary.start.addingTimeInterval(-24 * 60 * 60)
        let queryEnd = boundary.end.addingTimeInterval(
            SleepSessionSelector.maximumGap + 1
        )
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStart,
            end: queryEnd,
            options: []
        )
        let rawSamples: [HKCategorySample] = try await samples(
            type: type,
            predicate: predicate
        )
        let sorted = rawSamples.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.endDate < $1.endDate
        }
        let selectedUUIDs = SleepSessionSelector.sampleUUIDs(
            sorted,
            endingIn: boundary,
            completeThrough: .now
        )
        let selectedSamples = sorted.filter {
            selectedUUIDs.contains($0.uuid)
        }
        let values = selectedSamples
            .compactMap { sample -> SleepSample? in
                guard let stage = Self.sleepStage(for: sample.value) else {
                    return nil
                }
                return SleepSample(
                    id: sample.uuid.uuidString,
                    start: sample.startDate,
                    end: sample.endDate,
                    stage: stage
                )
            }
        return SleepResult(
            values: values,
            rawSamples: selectedSamples
        )
    }

    func workoutSamples(
        enabled: Bool,
        boundary: StoredDayBoundary
    ) async throws -> WorkoutResult {
        guard enabled else {
            return WorkoutResult(values: [], rawSamples: [])
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: boundary.start,
            end: boundary.end,
            options: [.strictStartDate]
        )
        let workouts: [HKWorkout] = try await samples(
            type: HKObjectType.workoutType(),
            predicate: predicate
        )
        let values = workouts.map { workout in
            WorkoutSample(
                id: workout.uuid.uuidString,
                type: Self.workoutTypeName(workout.workoutActivityType),
                start: workout.startDate,
                end: workout.endDate,
                activeEnergyKcal: Self.activeEnergy(for: workout),
                distanceMeters: Self.distance(for: workout)
            )
        }
        return WorkoutResult(values: values, rawSamples: workouts)
    }

    func sourceSamples(
        enabledMetrics: Set<HealthMetric>,
        start: Date,
        end: Date
    ) async throws -> [HKSample] {
        var result: [HKSample] = []
        for metric in HealthSourceSamplePlanner.directMetrics(
            from: enabledMetrics
        ) {
            guard let type = metric.sampleType else { continue }
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: [.strictStartDate]
            )
            let values: [HKSample] = try await samples(
                type: type,
                predicate: predicate
            )
            result.append(contentsOf: values)
        }
        return result
    }

    func samples<Sample: HKSample>(
        type: HKSampleType,
        predicate: NSPredicate
    ) async throws -> [Sample] {
        try await executeCancellableQuery { resume in
            HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                resume.resume(returning: samples as? [Sample] ?? [])
            }
        }
    }

    static func sleepStage(for rawValue: Int) -> SleepStage? {
        switch rawValue {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            .inBed
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            .asleepUnspecified
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            .awake
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            .asleepCore
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            .asleepDeep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            .asleepREM
        default:
            nil
        }
    }

    static func activeEnergy(for workout: HKWorkout) -> Double? {
        guard
            let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        else {
            return nil
        }
        return workout.statistics(for: type)?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())
    }

    static func distance(for workout: HKWorkout) -> Double? {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports,
        ]
        let values = identifiers.compactMap { identifier -> Double? in
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
                return nil
            }
            return workout.statistics(for: type)?
                .sumQuantity()?
                .doubleValue(for: .meter())
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining:
            "traditionalStrengthTraining"
        case .functionalStrengthTraining:
            "functionalStrengthTraining"
        case .highIntensityIntervalTraining:
            "highIntensityIntervalTraining"
        case .coreTraining:
            "coreTraining"
        case .running:
            "running"
        case .walking:
            "walking"
        case .hiking:
            "hiking"
        case .cycling:
            "cycling"
        case .swimming:
            "swimming"
        case .rowing:
            "rowing"
        case .elliptical:
            "elliptical"
        case .stairClimbing:
            "stairClimbing"
        case .yoga:
            "yoga"
        case .pilates:
            "pilates"
        case .dance:
            "dance"
        case .mixedCardio:
            "mixedCardio"
        default:
            "activity-\(type.rawValue)"
        }
    }
}

enum HealthKitCumulativeResult {
    static func resolve(_ value: Double?, error: Error?) throws -> Double? {
        guard let error else { return value }
        let nsError = error as NSError
        guard
            nsError.domain == HKErrorDomain,
            nsError.code == HKError.errorNoData.rawValue
        else {
            throw error
        }
        return nil
    }
}

enum HealthSourceSamplePlanner {
    static func directMetrics(
        from enabledMetrics: Set<HealthMetric>
    ) -> Set<HealthMetric> {
        enabledMetrics.intersection([
            .stepCount,
            .activeEnergy,
            .restingEnergy,
        ])
    }
}

enum HealthSourceProvenance {
    static func reusedQuantitySamples(
        enabledMetrics: Set<HealthMetric>,
        bodyMass: [HKQuantitySample],
        restingHeartRate: [HKQuantitySample],
        hrv: [HKQuantitySample]
    ) -> [HKQuantitySample] {
        var samples: [HKQuantitySample] = []
        if enabledMetrics.contains(.bodyMass) {
            samples.append(contentsOf: bodyMass)
        }
        if enabledMetrics.contains(.restingHeartRate) {
            samples.append(contentsOf: restingHeartRate)
        }
        if enabledMetrics.contains(.hrvSDNN) {
            samples.append(contentsOf: hrv)
        }
        return samples
    }

    static func uniqueSamples(
        directSamples: [HKSample],
        reusedQuantitySamples: [HKQuantitySample],
        selectedSamples: [HKSample]
    ) -> [UUID: HKSample] {
        (directSamples + reusedQuantitySamples + selectedSamples)
            .reduce(into: [:]) { samplesByID, sample in
                samplesByID[sample.uuid] = sample
            }
    }
}

enum SleepSessionSelector {
    static let maximumGap: TimeInterval = 4 * 60 * 60

    static func sampleUUIDs(
        _ samples: [HKCategorySample],
        endingIn boundary: StoredDayBoundary,
        completeThrough: Date
    ) -> Set<UUID> {
        struct Cluster {
            var end: Date
            var uuids: Set<UUID>
        }

        var clusters: [Cluster] = []
        for sample in samples {
            if
                let last = clusters.indices.last,
                sample.startDate.timeIntervalSince(clusters[last].end) <= maximumGap
            {
                clusters[last].end = max(clusters[last].end, sample.endDate)
                clusters[last].uuids.insert(sample.uuid)
            } else {
                clusters.append(
                    Cluster(end: sample.endDate, uuids: [sample.uuid])
                )
            }
        }

        return clusters
            .filter {
                $0.end >= boundary.start
                    && $0.end < boundary.end
                    && completeThrough.timeIntervalSince($0.end) >= maximumGap
            }
            .reduce(into: Set<UUID>()) { result, cluster in
                result.formUnion(cluster.uuids)
            }
    }
}
