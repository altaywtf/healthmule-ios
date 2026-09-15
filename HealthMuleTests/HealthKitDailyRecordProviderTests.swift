@preconcurrency import HealthKit
import HealthMuleCore
import XCTest
@testable import HealthMule

final class HealthKitDailyRecordProviderTests: XCTestCase {
    func testStatisticsResultPreservesValueWhenQuerySucceeds() throws {
        XCTAssertEqual(
            try HealthKitCumulativeResult.resolve(42, error: nil),
            42
        )
        XCTAssertNil(
            try HealthKitCumulativeResult.resolve(nil, error: nil)
        )
    }

    func testStatisticsNoDataResolvesToMissingMetric() throws {
        let noData = NSError(
            domain: HKErrorDomain,
            code: HKError.errorNoData.rawValue
        )

        XCTAssertNil(
            try HealthKitCumulativeResult.resolve(42, error: noData)
        )
    }

    func testStatisticsErrorsOtherThanNoDataRemainFailures() {
        let databaseUnavailable = NSError(
            domain: HKErrorDomain,
            code: HKError.errorDatabaseInaccessible.rawValue
        )
        let unrelatedErrorWithMatchingCode = NSError(
            domain: "HealthMuleTests",
            code: HKError.errorNoData.rawValue
        )

        XCTAssertThrowsError(
            try HealthKitCumulativeResult.resolve(
                42,
                error: databaseUnavailable
            )
        )
        XCTAssertThrowsError(
            try HealthKitCumulativeResult.resolve(
                42,
                error: unrelatedErrorWithMatchingCode
            )
        )
    }

    func testDirectSourceMetricsExcludeSeparatelyAggregatedTypes() {
        XCTAssertEqual(
            HealthSourceSamplePlanner.directMetrics(
                from: Set(HealthMetric.allCases)
            ),
            Set([
                .stepCount,
                .activeEnergy,
                .restingEnergy,
            ])
        )
    }

    func testReusedQuantitySamplesPreserveProvenanceWithoutDuplicates() throws {
        let phone = HKDevice(
            name: "Phone",
            manufacturer: nil,
            model: nil,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
        let watch = HKDevice(
            name: "Watch",
            manufacturer: nil,
            model: nil,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
        let weight = try quantitySample(
            identifier: .bodyMass,
            value: 70,
            unit: .gramUnit(with: .kilo),
            device: phone
        )
        let steps = try quantitySample(
            identifier: .stepCount,
            value: 1_000,
            unit: .count(),
            device: watch
        )
        let restingHeartRate = try quantitySample(
            identifier: .restingHeartRate,
            value: 60,
            unit: .count().unitDivided(by: .minute()),
            device: watch
        )
        let hrv = try quantitySample(
            identifier: .heartRateVariabilitySDNN,
            value: 40,
            unit: .secondUnit(with: .milli),
            device: watch
        )
        let oldSamples = HealthSourceProvenance.uniqueSamples(
            directSamples: [weight, steps, restingHeartRate, hrv],
            reusedQuantitySamples: [],
            selectedSamples: []
        )
        let newSamples = HealthSourceProvenance.uniqueSamples(
            directSamples: [steps],
            reusedQuantitySamples: HealthSourceProvenance.reusedQuantitySamples(
                enabledMetrics: [.bodyMass, .restingHeartRate, .hrvSDNN],
                bodyMass: [weight, weight],
                restingHeartRate: [restingHeartRate],
                hrv: [hrv]
            ),
            selectedSamples: []
        )

        XCTAssertEqual(Set(newSamples.keys), Set(oldSamples.keys))
        XCTAssertEqual(newSamples.count, oldSamples.count)
        XCTAssertEqual(
            Set(newSamples.values.compactMap(\.device?.name)),
            Set(["Phone", "Watch"])
        )
    }

    func testReusedQuantitySamplesOmitDisabledMetrics() throws {
        let weight = try quantitySample(
            identifier: .bodyMass,
            value: 70,
            unit: .gramUnit(with: .kilo),
            device: HKDevice.local()
        )
        let restingHeartRate = try quantitySample(
            identifier: .restingHeartRate,
            value: 60,
            unit: .count().unitDivided(by: .minute()),
            device: HKDevice.local()
        )

        let samples = HealthSourceProvenance.reusedQuantitySamples(
            enabledMetrics: [.restingHeartRate],
            bodyMass: [weight],
            restingHeartRate: [restingHeartRate],
            hrv: []
        )

        XCTAssertEqual(samples.map(\.uuid), [restingHeartRate.uuid])
        XCTAssertFalse(samples.contains { $0.uuid == weight.uuid })
    }

    func testVO2FetchWindowCoversLaterDaysFromTheFirstQuery() {
        let earliest = Date(timeIntervalSince1970: 0)
        let firstDayEnd = Date(timeIntervalSince1970: 86_400)
        let laterDayEnd = Date(timeIntervalSince1970: 86_400 * 30)
        let now = Date(timeIntervalSince1970: 86_400 * 40)
        let fetch = HealthKitQueryWindow.vo2FetchWindow(
            earliest: earliest,
            dayEnd: firstDayEnd,
            now: now
        )
        let laterDay = HealthKitQueryWindow.vo2DayWindow(
            earliest: earliest,
            dayEnd: laterDayEnd
        )

        XCTAssertTrue(fetch.covers(laterDay))
        XCTAssertEqual(fetch.start, earliest)
        XCTAssertEqual(
            fetch.end,
            now.addingTimeInterval(HealthKitQueryWindow.vo2FetchSlack)
        )
    }

    func testSleepFetchWindowFromOldestDayCoversALaterDayWindow() throws {
        let start = Date(timeIntervalSince1970: 86_400)
        let first = StoredDayBoundary(
            date: try LocalDate(rawValue: "2026-01-02"),
            timeZoneIdentifier: "UTC",
            start: start,
            end: start.addingTimeInterval(86_400)
        )
        let laterStart = start.addingTimeInterval(86_400 * 10)
        let later = StoredDayBoundary(
            date: try LocalDate(rawValue: "2026-01-12"),
            timeZoneIdentifier: "UTC",
            start: laterStart,
            end: laterStart.addingTimeInterval(86_400)
        )
        let now = later.end.addingTimeInterval(86_400)
        let fetch = HealthKitQueryWindow.sleepFetchWindow(
            boundary: first,
            now: now
        )

        XCTAssertTrue(fetch.covers(HealthKitQueryWindow.sleepDayWindow(boundary: later)))
    }

    func testCachedVO2SamplesMatchAPerDayStrictEndDatePredicate() throws {
        let earliest = Date(timeIntervalSince1970: 0)
        let dayEnd = Date(timeIntervalSince1970: 86_400)
        let included = try quantitySample(
            identifier: .vo2Max,
            value: 40,
            unit: HKUnit(from: "ml/kg*min"),
            device: HKDevice.local(),
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let excluded = try quantitySample(
            identifier: .vo2Max,
            value: 42,
            unit: HKUnit(from: "ml/kg*min"),
            device: HKDevice.local(),
            start: Date(timeIntervalSince1970: 90_000),
            end: Date(timeIntervalSince1970: 90_100)
        )
        let cache = HealthKitSampleWindowCache(
            window: HealthKitQueryWindow.vo2FetchWindow(
                earliest: earliest,
                dayEnd: dayEnd,
                now: Date(timeIntervalSince1970: 200_000)
            ),
            samples: [included, excluded]
        )
        let filtered = cache.samples(
            in: HealthKitQueryWindow.vo2DayWindow(
                earliest: earliest,
                dayEnd: dayEnd
            ),
            options: [.strictEndDate]
        )

        XCTAssertEqual(filtered.map(\.uuid), [included.uuid])
    }

    private func quantitySample(
        identifier: HKQuantityTypeIdentifier,
        value: Double,
        unit: HKUnit,
        device: HKDevice,
        start: Date = Date(timeIntervalSince1970: 1_000),
        end: Date = Date(timeIntervalSince1970: 1_001)
    ) throws -> HKQuantitySample {
        let type = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: identifier)
        )
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start,
            end: end,
            device: device,
            metadata: nil
        )
    }
}
