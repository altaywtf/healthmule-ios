@preconcurrency import HealthKit
import Foundation

enum HealthMetric: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case bodyMass
    case stepCount
    case activeEnergy
    case restingEnergy
    case restingHeartRate
    case hrvSDNN
    case vo2Max
    case sleep
    case workouts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bodyMass:
            "Body mass"
        case .stepCount:
            "Steps"
        case .activeEnergy:
            "Active energy"
        case .restingEnergy:
            "Resting energy"
        case .restingHeartRate:
            "Resting heart rate"
        case .hrvSDNN:
            "Heart-rate variability"
        case .vo2Max:
            "VO₂ max"
        case .sleep:
            "Sleep"
        case .workouts:
            "Workouts"
        }
    }

    var explanation: String {
        switch self {
        case .bodyMass:
            "Exports the latest weight sample for each day in kilograms."
        case .stepCount:
            "Exports HealthKit’s de-duplicated daily step total."
        case .activeEnergy:
            "Exports the daily active-energy total in kilocalories."
        case .restingEnergy:
            "Exports the daily basal or resting-energy total in kilocalories."
        case .restingHeartRate:
            "Exports the daily mean resting heart rate in beats per minute."
        case .hrvSDNN:
            "Exports the daily mean SDNN heart-rate variability in milliseconds."
        case .vo2Max:
            "Exports the latest available VO₂ max at or before each day."
        case .sleep:
            "Exports de-duplicated asleep-stage minutes for sessions ending that day."
        case .workouts:
            "Exports workout type, timing, duration, energy, and distance. Routes are excluded."
        }
    }

    var sampleType: HKSampleType? {
        switch self {
        case .bodyMass:
            HKObjectType.quantityType(forIdentifier: .bodyMass)
        case .stepCount:
            HKObjectType.quantityType(forIdentifier: .stepCount)
        case .activeEnergy:
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case .restingEnergy:
            HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)
        case .restingHeartRate:
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .hrvSDNN:
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .vo2Max:
            HKObjectType.quantityType(forIdentifier: .vo2Max)
        case .sleep:
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .workouts:
            HKObjectType.workoutType()
        }
    }

    static func readTypes(
        for metrics: Set<HealthMetric>
    ) -> Set<HKObjectType> {
        Set(metrics.compactMap(\.sampleType))
    }
}
