import Foundation
import Testing
@testable import HealthMuleCore

@Suite("Schema v1")
struct SchemaTests {
    @Test
    func missingPermissionsEncodeAsExplicitNulls() throws {
        let record = DailyHealthRecord(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZone: "Europe/Istanbul",
            generatedAt: try ISO8601Timestamp(
                rawValue: "2026-07-23T18:10:00+03:00"
            ),
            metrics: DailyHealthMetrics(),
            workouts: [],
            totals: WorkoutTotals(
                workoutMinutes: 0,
                workoutActiveEnergyKcal: 0
            ),
            sources: HealthRecordSources(deviceNames: [], sampleCount: 0)
        )

        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "missing-permissions",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        var expected = try Data(contentsOf: fixtureURL)
        if expected.last != 0x0A {
            expected.append(0x0A)
        }
        #expect(try DailyHealthRecordCodec.encode(record) == expected)
    }

    @Test
    func unknownFieldsSurviveDecodeUpdateAndReencode() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "date": "2026-07-23",
              "timeZone": "Europe/Istanbul",
              "generatedAt": "2026-07-23T18:10:00+03:00",
              "futureRoot": {"enabled": true},
              "metrics": {
                "weightKg": 82.9,
                "steps": null,
                "activeEnergyKcal": null,
                "restingEnergyKcal": null,
                "restingHeartRateBpm": null,
                "hrvSdnnMs": null,
                "vo2MaxMlKgMin": null,
                "sleepMinutes": null,
                "futureMetric": "kept",
                "futurePrecision": 913.1100000000049
              },
              "workouts": [{
                "id": "workout-1",
                "type": "running",
                "startedAt": "2026-07-23T07:00:00+03:00",
                "endedAt": "2026-07-23T08:00:00+03:00",
                "durationMinutes": 60,
                "activeEnergyKcal": null,
                "distanceMeters": null,
                "futureWorkout": 42
              }],
              "totals": {
                "workoutMinutes": 60,
                "workoutActiveEnergyKcal": 0,
                "futureTotal": null
              },
              "sources": {
                "deviceNames": ["Apple Watch"],
                "sampleCount": 1,
                "futureSource": [1, 2]
              }
            }
            """.utf8
        )
        let prior = try DailyHealthRecordCodec.decode(data)
        var update = prior
        update.metrics.weightKg = 83.1
        update.additionalFields = [:]
        update.metrics.additionalFields = [:]
        update.workouts[0].additionalFields = [:]
        update.totals.additionalFields = [:]
        update.sources.additionalFields = [:]

        let merged = update.preservingUnknownFields(from: prior)
        let roundTrip = try DailyHealthRecordCodec.decode(
            DailyHealthRecordCodec.encode(merged)
        )
        let futurePrecision = try decimal("913.1100000000049")

        #expect(roundTrip.additionalFields["futureRoot"] == .object(["enabled": .bool(true)]))
        #expect(roundTrip.metrics.additionalFields["futureMetric"] == .string("kept"))
        #expect(
            roundTrip.metrics.additionalFields["futurePrecision"]
                == .number(futurePrecision)
        )
        #expect(roundTrip.workouts[0].additionalFields["futureWorkout"] == .integer(42))
        #expect(roundTrip.totals.additionalFields["futureTotal"] == .null)
        #expect(
            roundTrip.sources.additionalFields["futureSource"]
                == .array([.integer(1), .integer(2)])
        )
        #expect(roundTrip.metrics.weightKg == 83.1)
    }

    @Test
    func semanticEqualityIgnoresGenerationTimeAndCollectionOrder() throws {
        let first = try sampleRecord(
            generatedAt: "2026-07-23T18:10:00+03:00",
            deviceNames: ["iPhone", "Apple Watch"]
        )
        var second = try sampleRecord(
            generatedAt: "2026-07-23T18:20:00+03:00",
            deviceNames: ["Apple Watch", "iPhone", "Apple Watch"]
        )
        second.workouts.reverse()

        #expect(try DailyHealthRecordCodec.semanticallyEqual(first, second))
        second.metrics.steps = 11
        #expect(try !DailyHealthRecordCodec.semanticallyEqual(first, second))
    }

    @Test
    func codecQuantizesKnownValuesButPreservesUnknownNumbers() throws {
        var noisy = try sampleRecord(
            generatedAt: "2026-07-23T18:10:00+03:00",
            deviceNames: ["iPhone"]
        )
        let futurePrecision = try decimal("913.1100000000049")
        noisy.metrics.activeEnergyKcal = 913.1100000000049
        noisy.metrics.additionalFields["futurePrecision"] =
            .number(futurePrecision)
        noisy.workouts[0].durationMinutes = 61.99999999999999
        noisy.workouts[0].activeEnergyKcal = 312.126
        noisy.totals.workoutMinutes = 999
        noisy.totals.workoutActiveEnergyKcal = 999

        let encoded = try DailyHealthRecordCodec.encode(noisy)
        let normalized = try DailyHealthRecordCodec.decode(encoded)
        let normalizedWorkout = try #require(
            normalized.workouts.first { $0.id == "b" }
        )
        var clean = noisy
        clean.metrics.activeEnergyKcal = 913.11
        clean.workouts[0].durationMinutes = 62
        clean.workouts[0].activeEnergyKcal = 312.13

        #expect(normalized.metrics.activeEnergyKcal == 913.11)
        #expect(normalizedWorkout.durationMinutes == 62)
        #expect(normalizedWorkout.activeEnergyKcal == 312.13)
        #expect(
            normalized.totals.workoutMinutes
                == normalized.workouts.map(\.durationMinutes).reduce(0, +)
        )
        #expect(
            normalized.totals.workoutActiveEnergyKcal
                == normalized.workouts.compactMap(\.activeEnergyKcal).reduce(0, +)
        )
        #expect(
            normalized.metrics.additionalFields["futurePrecision"]
                == .number(futurePrecision)
        )
        #expect(try DailyHealthRecordCodec.semanticallyEqual(noisy, clean))
    }

    @Test
    func unknownNumberBeyondInt64RoundTripsExactly() throws {
        let base = try DailyHealthRecordCodec.encode(
            sampleRecord(
                generatedAt: "2026-07-23T18:10:00+03:00",
                deviceNames: ["iPhone"]
            )
        )
        let numericLiteral = "9223372036854775809"
        let data = addingRootField(
            "\"futureWideInteger\":\(numericLiteral)",
            to: base
        )

        let decoded = try DailyHealthRecordCodec.decode(data)
        #expect(
            decoded.additionalFields["futureWideInteger"]
                == .number(try decimal(numericLiteral))
        )
        let reencoded = try DailyHealthRecordCodec.encode(decoded)
        #expect(
            String(decoding: reencoded, as: UTF8.self)
                .contains("\"futureWideInteger\":\(numericLiteral)")
        )
    }

    @Test
    func numericPreflightRejectsMoreThanThirtyEightSignificantDigits() throws {
        var record = try sampleRecord(
            generatedAt: "2026-07-23T18:10:00+03:00",
            deviceNames: ["iPhone"]
        )
        let numericText = "123456789012345678901234567890123456789"
        record.additionalFields["futureNumericText"] =
            .string("escaped quote: \\\"\(numericText)")
        let base = try DailyHealthRecordCodec.encode(record)
        _ = try DailyHealthRecordCodec.decode(base)

        let tooPrecise = addingRootField(
            "\"futureWideInteger\":\(numericText)",
            to: base
        )
        #expect(throws: SchemaValidationError.self) {
            _ = try DailyHealthRecordCodec.decode(tooPrecise)
        }

        let exponentOverflow = addingRootField(
            "\"futureExponent\":1e400",
            to: base
        )
        #expect(throws: DecodingError.self) {
            _ = try DailyHealthRecordCodec.decode(exponentOverflow)
        }
    }

    @Test
    func rejectsInvalidCalendarDatesAndOffsetlessTimestamps() {
        #expect(throws: SchemaValidationError.self) {
            _ = try LocalDate(rawValue: "2026-02-30")
        }
        #expect(throws: SchemaValidationError.self) {
            _ = try LocalDate(rawValue: "2026-0é-3")
        }
        #expect(throws: SchemaValidationError.self) {
            _ = try ISO8601Timestamp(rawValue: "2026-07-23T18:10:00")
        }
        #expect(throws: SchemaValidationError.self) {
            _ = try ISO8601Timestamp(rawValue: "5828963-12-20T00:00:00Z")
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        for interval in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Double.greatestFiniteMagnitude,
        ] {
            #expect(throws: SchemaValidationError.self) {
                _ = try ISO8601Timestamp(
                    date: Date(timeIntervalSinceReferenceDate: interval),
                    timeZone: utc
                )
            }
        }
    }

    @Test(arguments: [
        "2026-02-30T12:00:00Z",
        "2025-02-29T12:00:00+03:00",
        "2026-07-23T18:10:00ZjunkZ",
        "2026-07-23T18:10:00+03:00junk+03:00",
        "2026-07-23T25:00:00Z",
        "2026-07-23T18:61:00Z",
    ])
    func rejectsMalformedTimestampComponents(_ rawValue: String) throws {
        #expect(throws: SchemaValidationError.invalidTimestamp(rawValue)) {
            _ = try ISO8601Timestamp(rawValue: rawValue)
        }
        let encoded = try JSONEncoder().encode(rawValue)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ISO8601Timestamp.self, from: encoded)
        }
    }

    @Test
    func renderingPreservesFractionalTimestampInstants() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 3 * 60 * 60))
        let date = Date(timeIntervalSince1970: 1_000.500_123_456)

        let rendered = try ISO8601Timestamp(
            date: date,
            timeZone: timeZone
        )

        #expect(
            rendered.rawValue
                == "1970-01-01T03:16:40.500123501+03:00"
        )
        #expect(try rendered.date() == date)
        #expect(
            try ISO8601Timestamp(
                date: Date(timeIntervalSince1970: 1_000),
                timeZone: timeZone
            ).rawValue == "1970-01-01T03:16:40+03:00"
        )
    }

    @Test
    func parsingAcceptsOptionalFractionalSecondsAcrossFoundationVersions()
        throws
    {
        let whole = try ISO8601Timestamp(
            rawValue: "2026-07-23T18:10:00+03:00"
        )
        let fractional = try ISO8601Timestamp(
            rawValue: "2026-07-23T18:10:00.125+03:00"
        )

        #expect(try fractional.date().timeIntervalSince(whole.date()) == 0.125)
    }

    @Test
    func codecsRejectUnsupportedTimeZoneIdentifiers() throws {
        var record = try sampleRecord(
            generatedAt: "2026-07-23T18:10:00+03:00",
            deviceNames: ["iPhone"]
        )
        record.timeZone = "not-a-time-zone"

        #expect(throws: SchemaValidationError.invalidTimeZone(record.timeZone)) {
            _ = try DailyHealthRecordCodec.encode(record)
        }
        let unvalidatedRecordData = try CanonicalJSON.encode(record)
        #expect(throws: SchemaValidationError.invalidTimeZone(record.timeZone)) {
            _ = try DailyHealthRecordCodec.decode(unvalidatedRecordData)
        }

        var manifest = ExportManifest(
            exporterVersion: "1.0.0",
            timeZone: "not-a-time-zone",
            lastSuccessfulSyncAt: try ISO8601Timestamp(
                rawValue: "2026-07-23T18:10:00+03:00"
            ),
            earliestDate: try LocalDate(rawValue: "2026-07-01"),
            latestDate: try LocalDate(rawValue: "2026-07-23"),
            recordCount: 23
        )
        #expect(throws: SchemaValidationError.invalidTimeZone(manifest.timeZone)) {
            _ = try ExportManifestCodec.encode(manifest)
        }
        let unvalidatedManifestData = try CanonicalJSON.encode(manifest)
        #expect(throws: SchemaValidationError.invalidTimeZone(manifest.timeZone)) {
            _ = try ExportManifestCodec.decode(unvalidatedManifestData)
        }

        manifest.timeZone = "UTC"
        _ = try ExportManifestCodec.decode(
            ExportManifestCodec.encode(manifest)
        )
    }

    @Test
    func codecDeduplicatesIdenticalWorkoutIDsAndRejectsConflicts() throws {
        var identical = try sampleRecord(
            generatedAt: "2026-07-23T18:10:00+03:00",
            deviceNames: ["iPhone"]
        )
        let duplicatedWorkout = try #require(identical.workouts.first)
        identical.workouts.append(duplicatedWorkout)
        identical.totals.workoutMinutes += duplicatedWorkout.durationMinutes
        identical.totals.workoutActiveEnergyKcal +=
            duplicatedWorkout.activeEnergyKcal ?? 0

        let deduplicated = try DailyHealthRecordCodec.decode(
            DailyHealthRecordCodec.encode(identical)
        )
        #expect(deduplicated.workouts.count == 2)
        #expect(deduplicated.workouts.filter { $0.id == duplicatedWorkout.id }.count == 1)
        #expect(deduplicated.totals.workoutMinutes == 120)
        #expect(deduplicated.totals.workoutActiveEnergyKcal == 400)

        var conflicting = identical
        conflicting.workouts[2].additionalFields["conflict"] = .bool(true)
        #expect(
            throws: SchemaValidationError.conflictingWorkoutID(
                duplicatedWorkout.id
            )
        ) {
            _ = try DailyHealthRecordCodec.encode(conflicting)
        }

        let unvalidatedConflictData = try CanonicalJSON.encode(conflicting)
        #expect(
            throws: SchemaValidationError.conflictingWorkoutID(
                duplicatedWorkout.id
            )
        ) {
            _ = try DailyHealthRecordCodec.decode(unvalidatedConflictData)
        }
    }

    private func addingRootField(_ field: String, to data: Data) -> Data {
        let json = String(decoding: data, as: UTF8.self)
        return Data(("{\(field)," + String(json.dropFirst())).utf8)
    }

    private func decimal(_ rawValue: String) throws -> Decimal {
        try #require(
            Decimal(
                string: rawValue,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private func sampleRecord(
        generatedAt: String,
        deviceNames: [String]
    ) throws -> DailyHealthRecord {
        let workouts = [
            WorkoutRecord(
                id: "b",
                type: "running",
                startedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T09:00:00+03:00"
                ),
                endedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T10:00:00+03:00"
                ),
                durationMinutes: 60,
                activeEnergyKcal: 400,
                distanceMeters: 10_000
            ),
            WorkoutRecord(
                id: "a",
                type: "strength",
                startedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T07:00:00+03:00"
                ),
                endedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T08:00:00+03:00"
                ),
                durationMinutes: 60,
                activeEnergyKcal: nil,
                distanceMeters: nil
            ),
        ]
        return DailyHealthRecord(
            date: try LocalDate(rawValue: "2026-07-23"),
            timeZone: "Europe/Istanbul",
            generatedAt: try ISO8601Timestamp(rawValue: generatedAt),
            metrics: DailyHealthMetrics(steps: 10),
            workouts: workouts,
            totals: WorkoutTotals(
                workoutMinutes: 120,
                workoutActiveEnergyKcal: 400
            ),
            sources: HealthRecordSources(
                deviceNames: deviceNames,
                sampleCount: 3
            )
        )
    }
}
