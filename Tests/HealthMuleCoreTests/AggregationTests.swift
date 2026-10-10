import Foundation
import Testing
@testable import HealthMuleCore

@Suite("Daily aggregation")
struct AggregationTests {
    @Test
    func overlappingSleepIsUnionedAndAwakeIntervalsAreExcluded() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "overlapping-sleep",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let fixture = try decoder.decode(
            OverlappingSleepFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let samples = fixture.input.map {
            SleepSample(id: $0.id, start: $0.start, end: $0.end, stage: $0.stage)
        }

        #expect(
            try DailyHealthRecordAggregator.sleepMinutes(from: samples)
                == fixture.expectedSleepMinutes
        )
    }

    @Test
    func aggregationUsesLatestMeansAndDerivedWorkoutTotals() throws {
        let early = try date("2026-07-23T06:00:00Z")
        let late = try date("2026-07-23T07:00:00Z")
        let input = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "Europe/Istanbul",
            weightSamples: [
                TimedQuantitySample(id: "old", measuredAt: early, value: 82),
                TimedQuantitySample(id: "new", measuredAt: late, value: 83),
            ],
            steps: 10_432,
            activeEnergyKcal: 1_004.2,
            restingEnergyKcal: 2_016,
            restingHeartRateSamples: [
                TimedQuantitySample(id: "r1", measuredAt: early, value: 56),
                TimedQuantitySample(id: "r2", measuredAt: late, value: 60),
            ],
            hrvSamples: [
                TimedQuantitySample(id: "h1", measuredAt: early, value: 45),
                TimedQuantitySample(id: "h2", measuredAt: late, value: 50),
            ],
            vo2MaxSamples: [
                TimedQuantitySample(id: "v1", measuredAt: early, value: 40),
                TimedQuantitySample(id: "v2", measuredAt: late, value: 41.2),
            ],
            sleepSamples: [],
            workouts: [
                WorkoutSample(
                    id: "workout",
                    type: "traditionalStrengthTraining",
                    start: early,
                    end: late,
                    activeEnergyKcal: 312,
                    distanceMeters: nil
                ),
                WorkoutSample(
                    id: "workout",
                    type: "traditionalStrengthTraining",
                    start: early,
                    end: late,
                    activeEnergyKcal: 312,
                    distanceMeters: nil
                ),
            ],
            sourceDeviceNames: ["iPhone", "Apple Watch", "iPhone"],
            sampleCount: 12
        )

        let record = try DailyHealthRecordAggregator.aggregate(
            input,
            generatedAt: late
        )

        #expect(record.metrics.weightKg == 83)
        #expect(record.metrics.restingHeartRateBpm == 58)
        #expect(record.metrics.hrvSdnnMs == 47.5)
        #expect(record.metrics.vo2MaxMlKgMin == 41.2)
        #expect(record.metrics.sleepMinutes == 0)
        #expect(record.workouts.count == 1)
        #expect(record.totals.workoutMinutes == 60)
        #expect(record.totals.workoutActiveEnergyKcal == 312)
        #expect(record.sources.deviceNames == ["Apple Watch", "iPhone"])
        #expect(record.generatedAt.rawValue == "2026-07-23T10:00:00+03:00")
    }

    @Test
    func healthKitCumulativeValueWinsAcrossMultipleSources() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "multiple-sources",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let fixture = try JSONDecoder().decode(
            MultipleSourcesFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let record = try DailyHealthRecordAggregator.aggregate(
            DailyAggregationInput(
                date: try LocalDate(rawValue: "2026-07-23"),
                timeZoneIdentifier: "UTC",
                steps: fixture.input.healthKitCumulativeStepSum
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(record.metrics.steps == fixture.expected.steps)
        #expect(
            fixture.input.rawSamplesForDiagnosticsOnly.map(\.value).reduce(0, +)
                != fixture.expected.steps
        )
    }

    @Test
    func unreadableSleepRemainsNull() throws {
        let input = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "UTC",
            sleepSamples: nil
        )
        let record = try DailyHealthRecordAggregator.aggregate(
            input,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(record.metrics.sleepMinutes == nil)
    }

    @Test
    func invalidIntervalsAndNonFiniteValuesFailClosed() throws {
        let now = Date()
        let invalidSleep = SleepSample(
            id: "invalid",
            start: now,
            end: now.addingTimeInterval(-1),
            stage: .asleepCore
        )
        #expect(throws: AggregationError.self) {
            _ = try DailyHealthRecordAggregator.sleepMinutes(from: [invalidSleep])
        }

        let input = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "UTC",
            weightSamples: [
                TimedQuantitySample(id: "nan", measuredAt: now, value: .nan)
            ]
        )
        #expect(throws: AggregationError.self) {
            _ = try DailyHealthRecordAggregator.aggregate(input, generatedAt: now)
        }

        let invalidTimestampInput = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "UTC",
            weightSamples: [
                TimedQuantitySample(
                    id: "infinite-date",
                    measuredAt: Date(timeIntervalSinceReferenceDate: .infinity),
                    value: 82
                )
            ]
        )
        #expect(throws: AggregationError.self) {
            _ = try DailyHealthRecordAggregator.aggregate(
                invalidTimestampInput,
                generatedAt: now
            )
        }
    }

    @Test
    func knownDecimalMeasurementsAreQuantizedBeforeExport() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(3_719.999999999999)
        let input = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "UTC",
            weightSamples: [
                TimedQuantitySample(
                    id: "weight",
                    measuredAt: start,
                    value: 82.1234
                )
            ],
            activeEnergyKcal: 913.1100000000049,
            restingEnergyKcal: -0.004,
            restingHeartRateSamples: [
                TimedQuantitySample(id: "heart", measuredAt: start, value: 61.9999)
            ],
            hrvSamples: [
                TimedQuantitySample(id: "hrv", measuredAt: start, value: 47.555)
            ],
            vo2MaxSamples: [
                TimedQuantitySample(id: "vo2", measuredAt: start, value: 41.234)
            ],
            sleepSamples: [
                SleepSample(
                    id: "sleep",
                    start: start,
                    end: end,
                    stage: .asleepCore
                )
            ],
            workouts: [
                WorkoutSample(
                    id: "workout",
                    type: "running",
                    start: start,
                    end: end,
                    activeEnergyKcal: 312.126,
                    distanceMeters: 10_000.999
                )
            ]
        )

        let record = try DailyHealthRecordAggregator.aggregate(
            input,
            generatedAt: start
        )
        let encoded = try #require(
            String(data: DailyHealthRecordCodec.encode(record), encoding: .utf8)
        )

        #expect(record.metrics.weightKg == 82.12)
        #expect(record.metrics.activeEnergyKcal == 913.11)
        #expect(record.metrics.restingEnergyKcal == 0)
        #expect(record.metrics.restingHeartRateBpm == 62)
        #expect(record.metrics.hrvSdnnMs == 47.56)
        #expect(record.metrics.vo2MaxMlKgMin == 41.23)
        #expect(record.metrics.sleepMinutes == 62)
        #expect(record.workouts[0].durationMinutes == 62)
        #expect(record.workouts[0].activeEnergyKcal == 312.13)
        #expect(record.workouts[0].distanceMeters == 10_001)
        #expect(!encoded.contains("913.1100000000049"))
        #expect(!encoded.contains("61.99999999999999"))
        #expect(!encoded.contains(":-0"))
    }

    @Test(arguments: [
        (1.005, 1.01), (4.015, 4.02), (-1.005, -1.01),
        (1.005.nextDown, 1.00), (1.005.nextUp, 1.01),
        ((-1.005).nextDown, -1.01), ((-1.005).nextUp, -1.00),
    ])
    func aggregationUsesDecimalMidpoints(value: Double, expected: Double) throws {
        let start = Date(timeIntervalSince1970: 0)
        let record = try DailyHealthRecordAggregator.aggregate(
            DailyAggregationInput(
                date: try LocalDate(rawValue: "2026-07-23"),
                timeZoneIdentifier: "UTC",
                activeEnergyKcal: value,
                restingHeartRateSamples: [
                    TimedQuantitySample(id: "heart", measuredAt: start, value: value)
                ],
                workouts: [
                    WorkoutSample(
                        id: "workout",
                        type: "other",
                        start: start,
                        end: start.addingTimeInterval(60),
                        activeEnergyKcal: value,
                        distanceMeters: nil
                    )
                ]
            ),
            generatedAt: start
        )
        #expect(record.metrics.activeEnergyKcal == expected)
        #expect(record.metrics.restingHeartRateBpm == expected)
        #expect(record.workouts[0].activeEnergyKcal == expected)
        #expect(record.totals.workoutActiveEnergyKcal == expected)
        let decoded = try DailyHealthRecordCodec.decode(DailyHealthRecordCodec.encode(record))
        #expect(decoded.metrics.activeEnergyKcal == expected)
        #expect(decoded.totals.workoutActiveEnergyKcal == expected)
    }

    @Test
    func workoutTotalsAreDerivedFromRoundedExportedWorkouts() throws {
        let start = Date(timeIntervalSince1970: 0)
        let duration = 0.004 * 60
        let workouts = ["first", "second"].map {
            WorkoutSample(
                id: $0,
                type: "other",
                start: start,
                end: start.addingTimeInterval(duration),
                activeEnergyKcal: 0.004,
                distanceMeters: nil
            )
        }
        let record = try DailyHealthRecordAggregator.aggregate(
            DailyAggregationInput(
                date: try LocalDate(rawValue: "2026-07-23"),
                timeZoneIdentifier: "UTC",
                workouts: workouts
            ),
            generatedAt: start
        )

        #expect(record.workouts.map(\.durationMinutes) == [0, 0])
        #expect(record.workouts.map(\.activeEnergyKcal) == [0, 0])
        #expect(record.totals.workoutMinutes == 0)
        #expect(record.totals.workoutActiveEnergyKcal == 0)
    }

    @Test
    func conflictingDuplicateWorkoutIDsFailClosedInEitherInputOrder() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(60 * 60)
        let withoutMeasurements = WorkoutSample(
            id: "workout",
            type: "running",
            start: start,
            end: end,
            activeEnergyKcal: nil,
            distanceMeters: nil
        )
        let withMeasurements = WorkoutSample(
            id: "workout",
            type: "running",
            start: start,
            end: end,
            activeEnergyKcal: 312,
            distanceMeters: 10_000
        )

        for workouts in [
            [withoutMeasurements, withMeasurements],
            [withMeasurements, withoutMeasurements],
        ] {
            #expect(
                throws: AggregationError.conflictingDuplicateSample(
                    sampleID: "workout"
                )
            ) {
                _ = try DailyHealthRecordAggregator.aggregate(
                    DailyAggregationInput(
                        date: try LocalDate(rawValue: "2026-07-23"),
                        timeZoneIdentifier: "UTC",
                        workouts: workouts
                    ),
                    generatedAt: start
                )
            }
        }
    }

    @Test
    func insignificantInputNoiseProducesTheSameSemanticRecord() throws {
        func record(activeEnergy: Double, generatedAt: Date) throws -> DailyHealthRecord {
            try DailyHealthRecordAggregator.aggregate(
                DailyAggregationInput(
                    date: try LocalDate(rawValue: "2026-07-23"),
                    timeZoneIdentifier: "UTC",
                    activeEnergyKcal: activeEnergy
                ),
                generatedAt: generatedAt
            )
        }

        let first = try record(
            activeEnergy: 913.1100000000049,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let second = try record(
            activeEnergy: 913.11,
            generatedAt: Date(timeIntervalSince1970: 60)
        )

        #expect(try DailyHealthRecordCodec.semanticallyEqual(first, second))
    }

    @Test
    func quantizingTheLargestFiniteValueDoesNotOverflow() throws {
        let record = try DailyHealthRecordAggregator.aggregate(
            DailyAggregationInput(
                date: try LocalDate(rawValue: "2026-07-23"),
                timeZoneIdentifier: "UTC",
                weightSamples: [
                    TimedQuantitySample(
                        id: "large",
                        measuredAt: Date(timeIntervalSince1970: 0),
                        value: .greatestFiniteMagnitude
                    )
                ]
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(record.metrics.weightKg?.isFinite == true)
        _ = try DailyHealthRecordCodec.encode(record)
    }

    @Test
    func nonFiniteDerivedValuesFailClosed() throws {
        let now = Date(timeIntervalSince1970: 0)
        let input = DailyAggregationInput(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZoneIdentifier: "UTC",
            restingHeartRateSamples: [
                TimedQuantitySample(
                    id: "first",
                    measuredAt: now,
                    value: .greatestFiniteMagnitude
                ),
                TimedQuantitySample(
                    id: "second",
                    measuredAt: now,
                    value: .greatestFiniteMagnitude
                ),
            ]
        )

        #expect(throws: AggregationError.self) {
            _ = try DailyHealthRecordAggregator.aggregate(
                input,
                generatedAt: now
            )
        }
    }

    @Test
    func overflowingSleepDurationFailsClosed() {
        let samples = [
            SleepSample(
                id: "first",
                start: Date(timeIntervalSinceReferenceDate: -1.7e308),
                end: Date(timeIntervalSinceReferenceDate: -0.7e308),
                stage: .asleepCore
            ),
            SleepSample(
                id: "second",
                start: Date(timeIntervalSinceReferenceDate: 0.7e308),
                end: Date(timeIntervalSinceReferenceDate: 1.7e308),
                stage: .asleepCore
            ),
        ]

        #expect(throws: AggregationError.self) {
            _ = try DailyHealthRecordAggregator.sleepMinutes(from: samples)
        }
    }

    private func date(_ string: String) throws -> Date {
        try ISO8601Timestamp(rawValue: string).date()
    }
}

private struct OverlappingSleepFixture: Decodable {
    struct Input: Decodable {
        let id: String
        let stage: SleepStage
        let start: Date
        let end: Date
    }

    let input: [Input]
    let expectedSleepMinutes: Double
}

private struct MultipleSourcesFixture: Decodable {
    struct Input: Decodable {
        struct RawSample: Decodable {
            let value: Int
        }

        let healthKitCumulativeStepSum: Int
        let rawSamplesForDiagnosticsOnly: [RawSample]
    }

    struct Expected: Decodable {
        let steps: Int
    }

    let input: Input
    let expected: Expected
}
