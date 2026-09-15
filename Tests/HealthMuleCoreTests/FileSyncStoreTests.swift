import Foundation
import Testing
@testable import HealthMuleCore

@Suite("Durable file sync store")
struct FileSyncStoreTests {
    @Test
    func dueArtifactCheckDoesNotReadArtifactContents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()

        _ = try await store.stageDaily(record)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(
                "daily/\(record.date.rawValue).json"
            )
        )

        #expect(
            try await store.hasDueArtifact(
                kind: .daily,
                at: .distantFuture
            )
        )
    }

    @Test
    func dailyDateIndexDoesNotReadArtifactContents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()

        _ = try await store.stageDaily(record)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(
                "daily/\(record.date.rawValue).json"
            )
        )

        #expect(try await store.allDailyDates() == [record.date])
        let cached = try await store.allDailyRecords()
        #expect(cached.map(\.date) == [record.date])
        #expect(cached.first?.metrics.steps == record.metrics.steps)
    }

    @Test
    func recoverCachesDailyRecordsWithoutRereadingFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await original.stageDaily(record)

        let store = try FileSyncStore(rootDirectory: directory)
        try await store.recover()
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(
                "daily/\(record.date.rawValue).json"
            )
        )

        #expect(try await store.allDailyDates() == [record.date])
        let cached = try await store.allDailyRecords()
        #expect(cached.map(\.date) == [record.date])
        #expect(cached.first?.metrics.steps == record.metrics.steps)
    }

    @Test
    func unchangedSemanticRecordKeepsOriginalGeneratedAtAndRevision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let first = try makeRecord()
        let second = try makeRecord(generatedAt: "2026-07-23T18:20:00+03:00")

        #expect(
            try await store.stageDaily(first)
                == .staged(.daily(first.date), revision: 1)
        )
        #expect(
            try await store.stageDaily(second)
                == .unchanged(.daily(first.date), revision: 1)
        )

        let storedData = try Data(
            contentsOf: directory.appendingPathComponent("daily/2026-07-23.json")
        )
        let stored = try DailyHealthRecordCodec.decode(storedData)
        #expect(stored.generatedAt == first.generatedAt)
        #expect(try await store.pendingUploadCount() == 1)
    }

    @Test
    func changedRecordPreservesPriorUnknownFields() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let first = try makeRecord(
            additionalFields: ["future": .object(["value": .integer(1)])]
        )
        let second = try makeRecord(steps: 11)

        _ = try await store.stageDaily(first)
        _ = try await store.stageDaily(second)

        let stored = try DailyHealthRecordCodec.decode(
            Data(contentsOf: directory.appendingPathComponent("daily/2026-07-23.json"))
        )
        #expect(stored.metrics.steps == 11)
        #expect(
            stored.additionalFields["future"]
                == .object(["value": .integer(1)])
        )
        let item = try #require(try await store.retryItems().first)
        #expect(item.revision == 2)
    }

    @Test
    func restagingAnExistingDatePreservesItsOriginalTimeZone() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        var original = try makeRecord()
        original.workouts = [
            WorkoutRecord(
                id: "workout-1",
                type: "running",
                startedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T10:00:00+03:00"
                ),
                endedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T11:00:00+03:00"
                ),
                durationMinutes: 60,
                activeEnergyKcal: nil,
                distanceMeters: nil
            )
        ]
        original.totals.workoutMinutes = 60
        var traveler = try makeRecord(
            timeZone: "America/New_York",
            generatedAt: "2026-07-23T11:10:00-04:00",
            steps: 11
        )
        traveler.workouts = [
            WorkoutRecord(
                id: "workout-1",
                type: "running",
                startedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T03:00:00-04:00"
                ),
                endedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T04:00:00-04:00"
                ),
                durationMinutes: 60,
                activeEnergyKcal: nil,
                distanceMeters: nil
            )
        ]
        traveler.totals.workoutMinutes = 60

        _ = try await store.stageDaily(original)
        #expect(
            try await store.stageDaily(traveler)
                == .staged(.daily(original.date), revision: 2)
        )

        let stored = try DailyHealthRecordCodec.decode(
            Data(contentsOf: directory.appendingPathComponent("daily/2026-07-23.json"))
        )
        #expect(stored.timeZone == original.timeZone)
        #expect(stored.generatedAt == original.generatedAt)
        #expect(stored.workouts.first?.startedAt == original.workouts.first?.startedAt)
        #expect(stored.workouts.first?.endedAt == original.workouts.first?.endedAt)
        #expect(stored.metrics.steps == 11)
    }

    @Test
    func equivalentTravelerTimestampsDoNotCreateARevision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        var original = try makeRecord()
        original.workouts = [
            WorkoutRecord(
                id: "workout-1",
                type: "running",
                startedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T10:00:00+03:00"
                ),
                endedAt: try ISO8601Timestamp(
                    rawValue: "2026-07-23T11:00:00+03:00"
                ),
                durationMinutes: 60,
                activeEnergyKcal: nil,
                distanceMeters: nil
            )
        ]
        original.totals.workoutMinutes = 60
        _ = try await store.stageDaily(original)
        let artifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await store.markUploaded(artifact)

        var traveler = original
        traveler.timeZone = "America/New_York"
        traveler.generatedAt = try ISO8601Timestamp(
            rawValue: "2026-07-23T11:10:00-04:00"
        )
        traveler.workouts[0].startedAt = try ISO8601Timestamp(
            rawValue: "2026-07-23T03:00:00-04:00"
        )
        traveler.workouts[0].endedAt = try ISO8601Timestamp(
            rawValue: "2026-07-23T04:00:00-04:00"
        )

        #expect(
            try await store.stageDaily(traveler)
                == .unchanged(.daily(original.date), revision: 1)
        )
        #expect(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).isEmpty
        )
    }

    @Test
    func legacyNumericRepresentationIsRewrittenAsCanonical() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dailyDirectory = directory.appendingPathComponent(
            "daily",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dailyDirectory,
            withIntermediateDirectories: true
        )
        let legacyData = Data(
            """
            {
              "schemaVersion": 1,
              "date": "2026-07-23",
              "timeZone": "Europe/Istanbul",
              "generatedAt": "2026-07-23T18:10:00+03:00",
              "metrics": {
                "weightKg": null,
                "steps": null,
                "activeEnergyKcal": 913.1100000000049,
                "restingEnergyKcal": null,
                "restingHeartRateBpm": null,
                "hrvSdnnMs": null,
                "vo2MaxMlKgMin": null,
                "sleepMinutes": null
              },
              "workouts": [],
              "totals": {
                "workoutMinutes": 0,
                "workoutActiveEnergyKcal": 0
              },
              "sources": {"deviceNames": [], "sampleCount": 0}
            }
            """.utf8
        )
        let fileURL = dailyDirectory.appendingPathComponent("2026-07-23.json")
        try legacyData.write(to: fileURL, options: [.atomic])
        let store = try FileSyncStore(rootDirectory: directory)
        let candidate = try DailyHealthRecordCodec.decode(legacyData)

        let recoveredArtifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        #expect(
            recoveredArtifact.contents
                == (try DailyHealthRecordCodec.encode(candidate))
        )
        #expect(
            try await store.stageDaily(candidate)
                == .unchanged(.daily(candidate.date), revision: 1)
        )
        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(rewritten.contains("913.11"))
        #expect(!rewritten.contains("913.1100000000049"))
    }

    @Test
    func currentDailyArtifactsCanBeDurablyRequeuedForRemoteRepair() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let firstUpload = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await store.markUploaded(firstUpload)

        try await store.enqueueCurrentDailyArtifactsForUpload()

        let repairUpload = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        #expect(repairUpload.id == .daily(record.date))
        #expect(repairUpload.revision == 2)
        let revisions = try #require(
            try await store.artifactState(for: .daily(record.date))
        )
        #expect(revisions.localRevision == 2)
        #expect(revisions.uploadedRevision == 1)
        #expect(try await store.manifestRequiresRefresh())
    }

    @Test
    func destinationChangeResetsEveryRemoteRevisionAndRetryState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let first = try makeRecord(date: "2026-07-22")
        let second = try makeRecord(date: "2026-07-23")
        _ = try await store.stageDaily(first)
        _ = try await store.stageDaily(second)

        let staged = try await store.dueArtifacts(
            at: Date(),
            includeDeferred: true
        )
        let firstArtifact = try #require(
            staged.first { $0.id == .daily(first.date) }
        )
        let secondArtifact = try #require(
            staged.first { $0.id == .daily(second.date) }
        )
        try await store.markUploaded(firstArtifact)
        try await store.markFailed(
            secondArtifact,
            error: .permanent(code: "old-account-failure"),
            now: Date(timeIntervalSince1970: 1_000),
            randomUnit: 0.5,
            retryPolicy: RetryPolicy()
        )
        let manifest = ExportManifest(
            exporterVersion: "1.0.0",
            timeZone: "Europe/Istanbul",
            lastSuccessfulSyncAt: try ISO8601Timestamp(
                rawValue: "2026-07-23T18:10:00+03:00"
            ),
            earliestDate: first.date,
            latestDate: second.date,
            recordCount: 2
        )
        _ = try await store.stageManifest(manifest)
        let manifestArtifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first { $0.id == .manifest }
        )
        try await store.markFailed(
            manifestArtifact,
            error: .permanent(code: "old-account-manifest"),
            now: Date(timeIntervalSince1970: 1_000),
            randomUnit: 0.5,
            retryPolicy: RetryPolicy()
        )

        try await store.resetRemoteUploadState()

        for record in [first, second] {
            let revisions = try #require(
                try await store.artifactState(for: .daily(record.date))
            )
            #expect(revisions.localRevision == 1)
            #expect(revisions.uploadedRevision == 0)
        }
        let retryItems = try await store.retryItems()
        #expect(retryItems.count == 2)
        #expect(retryItems.allSatisfy { $0.attemptCount == 0 })
        #expect(retryItems.allSatisfy { $0.blockReason == nil })
        #expect(retryItems.allSatisfy { $0.lastErrorCode == nil })
        #expect(!retryItems.contains { $0.artifactID == .manifest })
        #expect(try await store.artifactState(for: .manifest) == nil)
        #expect(try await store.manifestRequiresRefresh())

        let reopened = try FileSyncStore(rootDirectory: directory)
        #expect(try await reopened.pendingUploadCount() == 2)
        try await reopened.resetRemoteUploadState()
        #expect(try await reopened.pendingUploadCount() == 2)
    }

    @Test
    func unchangedPendingManifestRestoresItsQueueAfterInvalidation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord(steps: 10)
        _ = try await store.stageDaily(record)
        let firstDaily = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await store.markUploaded(firstDaily)

        let manifest = try makeTestManifest(for: record)
        #expect(
            try await store.stageManifest(manifest)
                == .staged(.manifest, revision: 1)
        )

        let changedRecord = try makeRecord(steps: 11)
        _ = try await store.stageDaily(changedRecord)
        let changedDaily = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first { $0.id == .daily(record.date) }
        )
        try await store.markUploaded(changedDaily)
        #expect(
            !(try await store.retryItems()).contains {
                $0.artifactID == .manifest
            }
        )
        #expect(try await store.manifestRequiresRefresh())

        #expect(
            try await store.stageManifest(manifest)
                == .unchanged(.manifest, revision: 1)
        )

        let manifestRetry = try #require(
            try await store.retryItems().first {
                $0.artifactID == .manifest
            }
        )
        #expect(manifestRetry.revision == 1)
        #expect(manifestRetry.attemptCount == 0)
        #expect(!(try await store.manifestRequiresRefresh()))
        let manifestArtifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first { $0.id == .manifest }
        )
        #expect(manifestArtifact.revision == 1)
    }

    @Test
    func missingManifestRecoveryDiscardsStaleStateBeforeRefresh() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try makeRecord()
        let firstStore = try FileSyncStore(rootDirectory: directory)
        _ = try await firstStore.stageDaily(record)
        let daily = try #require(
            try await firstStore.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await firstStore.markUploaded(daily)

        let manifest = try makeTestManifest(for: record)
        _ = try await firstStore.stageManifest(manifest)
        let manifestArtifact = try #require(
            try await firstStore.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first { $0.id == .manifest }
        )
        try await firstStore.markFailed(
            manifestArtifact,
            error: .permanent(code: "stale-manifest"),
            now: Date(timeIntervalSince1970: 1_000),
            randomUnit: 0.5,
            retryPolicy: RetryPolicy()
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manifest.json")
        )

        let reopened = try FileSyncStore(rootDirectory: directory)
        try await reopened.recover()

        #expect(
            !(try await reopened.retryItems()).contains {
                $0.artifactID == .manifest
            }
        )
        #expect(try await reopened.artifactState(for: .manifest) == nil)
        #expect(try await reopened.manifestRequiresRefresh())
        #expect(
            try await reopened.stageManifest(manifest)
                == .staged(.manifest, revision: 1)
        )
        #expect(
            (try await reopened.dueArtifacts(
                at: Date(),
                includeDeferred: true
            )).contains { $0.id == .manifest }
        )
    }

    @Test
    func queueSurvivesStoreReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try makeRecord()

        let firstStore = try FileSyncStore(rootDirectory: directory)
        _ = try await firstStore.stageDaily(record)

        let reopened = try FileSyncStore(rootDirectory: directory)
        let items = try await reopened.retryItems()
        #expect(items.count == 1)
        #expect(items[0].artifactID == .daily(record.date))
        #expect(items[0].revision == 1)
    }

    @Test
    func orphanArtifactIsRecoveredIntoRetryQueue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dailyDirectory = directory.appendingPathComponent("daily", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dailyDirectory,
            withIntermediateDirectories: true
        )
        let record = try makeRecord()
        try DailyHealthRecordCodec.encode(record).write(
            to: dailyDirectory.appendingPathComponent("2026-07-23.json"),
            options: [.atomic]
        )

        let store = try FileSyncStore(rootDirectory: directory)
        try await store.recover()

        let item = try #require(try await store.retryItems().first)
        #expect(item.artifactID == .daily(record.date))
        #expect(item.revision == 1)
    }

    @Test
    func artifactWrittenBeforeStateCommitIsRecoveredAsNextRevision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRecord = try makeRecord(steps: 10)
        let firstStore = try FileSyncStore(rootDirectory: directory)
        _ = try await firstStore.stageDaily(firstRecord)
        let uploadedArtifact = try #require(
            try await firstStore.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await firstStore.markUploaded(uploadedArtifact)

        let changedRecord = try makeRecord(steps: 11)
        try DailyHealthRecordCodec.encode(changedRecord).write(
            to: directory.appendingPathComponent("daily/2026-07-23.json"),
            options: [.atomic]
        )

        let reopened = try FileSyncStore(rootDirectory: directory)
        let item = try #require(try await reopened.retryItems().first)
        #expect(item.artifactID == .daily(firstRecord.date))
        #expect(item.revision == 2)
        let revisions = try #require(
            try await reopened.artifactState(for: .daily(firstRecord.date))
        )
        #expect(revisions.localRevision == 2)
        #expect(revisions.uploadedRevision == 1)
    }

    @Test
    func artifactWrittenBeforeStateCommitIsRecoveredWithoutReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRecord = try makeRecord(steps: 10)
        let store = try FileSyncStore(rootDirectory: directory)
        _ = try await store.stageDaily(firstRecord)
        let uploadedArtifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await store.markUploaded(uploadedArtifact)

        let changedRecord = try makeRecord(steps: 11)
        try DailyHealthRecordCodec.encode(changedRecord).write(
            to: directory.appendingPathComponent("daily/2026-07-23.json"),
            options: [.atomic]
        )

        #expect(
            try await store.stageDaily(changedRecord)
                == .staged(.daily(changedRecord.date), revision: 2)
        )
        let item = try #require(try await store.retryItems().first)
        #expect(item.artifactID == .daily(changedRecord.date))
        #expect(item.revision == 2)
        let revisions = try #require(
            try await store.artifactState(for: .daily(changedRecord.date))
        )
        #expect(revisions.localRevision == 2)
        #expect(revisions.uploadedRevision == 1)
        #expect(try await store.manifestRequiresRefresh())
    }

    @Test
    func firstArtifactIsRecoveredWithoutReopenAfterStateCommitFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        try await store.recover()
        let stateFile = directory.appendingPathComponent("sync-state.json")
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(
            at: stateFile,
            withIntermediateDirectories: false
        )
        let record = try makeRecord()

        do {
            _ = try await store.stageDaily(record)
            Issue.record("Expected the state commit to fail while its path is a directory.")
        } catch {}
        try FileManager.default.removeItem(at: stateFile)

        #expect(try await store.pendingUploadCount() == 1)
        let artifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        #expect(artifact.id == .daily(record.date))
        #expect(artifact.revision == 1)
        let item = try #require(try await store.retryItems().first)
        #expect(item.artifactID == .daily(record.date))
        #expect(item.revision == 1)
        let reopened = try FileSyncStore(rootDirectory: directory)
        #expect(try await reopened.pendingUploadCount() == 1)
    }

    @Test
    func formatOnlyArtifactDriftIsCanonicalizedWithoutNewRevision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try makeRecord()
        let artifactURL = directory.appendingPathComponent("daily/2026-07-23.json")
        let firstStore = try FileSyncStore(rootDirectory: directory)
        _ = try await firstStore.stageDaily(record)
        let firstArtifact = try #require(
            try await firstStore.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await firstStore.markUploaded(firstArtifact)

        let object = try JSONSerialization.jsonObject(with: firstArtifact.contents)
        let noncanonicalContents = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(noncanonicalContents != firstArtifact.contents)
        try noncanonicalContents.write(to: artifactURL, options: [.atomic])

        #expect(
            try await firstStore.stageDaily(record)
                == .unchanged(.daily(record.date), revision: 1)
        )
        #expect(
            try await firstStore.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).isEmpty
        )
        #expect(try Data(contentsOf: artifactURL) == firstArtifact.contents)
        let reopened = try FileSyncStore(rootDirectory: directory)
        let revisions = try #require(
            try await reopened.artifactState(for: .daily(record.date))
        )
        #expect(revisions.localRevision == 1)
        #expect(revisions.uploadedRevision == 1)
    }

    @Test
    func cancelledMarkUploadedDoesNotCommitState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let artifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        let barrier = CancellationBarrier()
        let markTask = Task {
            await barrier.pause()
            try await store.markUploaded(artifact)
        }

        await barrier.waitUntilPaused()
        markTask.cancel()
        await barrier.resume()

        do {
            try await markTask.value
            Issue.record("Expected cancelled markUploaded to throw.")
        } catch is CancellationError {}

        let revisions = try #require(
            try await store.artifactState(for: artifact.id)
        )
        #expect(revisions.localRevision == 1)
        #expect(revisions.uploadedRevision == 0)
        let retryItem = try #require(try await store.retryItems().first)
        #expect(retryItem.artifactID == artifact.id)
        #expect(retryItem.revision == artifact.revision)
    }

    @Test
    func cancelledReauthorizationUnblockDoesNotCommitState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let artifact = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true
            ).first
        )
        try await store.markFailed(
            artifact,
            error: .reauthorizationRequired(code: "401"),
            now: Date(timeIntervalSince1970: 1_000),
            randomUnit: 0.5,
            retryPolicy: RetryPolicy()
        )
        let barrier = CancellationBarrier()
        let unblockTask = Task {
            await barrier.pause()
            return try await store.unblockReauthorizationFailures(
                at: Date(timeIntervalSince1970: 2_000)
            )
        }

        await barrier.waitUntilPaused()
        unblockTask.cancel()
        await barrier.resume()

        do {
            _ = try await unblockTask.value
            Issue.record("Expected cancelled reauthorization unblock to throw.")
        } catch is CancellationError {}

        let retryItem = try #require(try await store.retryItems().first)
        #expect(retryItem.blockReason == .reauthorizationRequired)
        #expect(retryItem.notBefore == Date(timeIntervalSince1970: 0))
    }

    @Test
    func transientAndAuthorizationFailuresPersistDifferentRetryStates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let artifact = try #require(
            try await store.dueArtifacts(
                at: Date(timeIntervalSince1970: 100),
                includeDeferred: true
            ).first
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = RetryPolicy(
            initialDelay: 10,
            maximumDelay: 100,
            jitterRatio: 0
        )

        try await store.markFailed(
            artifact,
            error: .transient(code: "429"),
            now: now,
            randomUnit: 0.5,
            retryPolicy: policy
        )
        var item = try #require(try await store.retryItems().first)
        #expect(item.attemptCount == 1)
        #expect(item.notBefore == now.addingTimeInterval(10))
        #expect(item.blockReason == nil)

        try await store.markFailed(
            artifact,
            error: .reauthorizationRequired(code: "401"),
            now: now,
            randomUnit: 0.5,
            retryPolicy: policy
        )
        item = try #require(try await store.retryItems().first)
        #expect(item.attemptCount == 2)
        #expect(item.blockReason == .reauthorizationRequired)
        #expect(
            try await store.dueArtifacts(
                at: now.addingTimeInterval(1_000),
                includeDeferred: true
            ).isEmpty
        )
    }

    @Test
    func pendingManifestRefreshPreservesRetryStateAndUnknownFields() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let daily = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true,
                kind: .daily
            ).first
        )
        try await store.markUploaded(daily)

        var original = try makeTestManifest(for: record)
        original.additionalFields = [
            "future": .object(["value": .integer(1)])
        ]
        _ = try await store.stageManifest(original)
        let manifest = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true,
                kind: .manifest
            ).first
        )
        let failureTime = Date(timeIntervalSince1970: 1_000)
        try await store.markFailed(
            manifest,
            error: .transient(code: "timedOut"),
            now: failureTime,
            randomUnit: 0.5,
            retryPolicy: RetryPolicy(
                initialDelay: 100,
                maximumDelay: 100,
                jitterRatio: 0
            )
        )
        let retryBefore = try #require(
            try await store.retryItems().first {
                $0.artifactID == .manifest
            }
        )

        var refreshed = try makeTestManifest(for: record)
        refreshed.lastSuccessfulSyncAt = try ISO8601Timestamp(
            rawValue: "2026-07-23T18:20:00+03:00"
        )
        let refreshedArtifact = try await store.refreshPendingManifest(
            refreshed
        )
        let retryAfter = try #require(
            try await store.retryItems().first {
                $0.artifactID == .manifest
            }
        )
        let decoded = try ExportManifestCodec.decode(
            refreshedArtifact.contents
        )

        #expect(retryAfter == retryBefore)
        #expect(refreshedArtifact.revision == manifest.revision)
        #expect(decoded.lastSuccessfulSyncAt == refreshed.lastSuccessfulSyncAt)
        #expect(
            decoded.additionalFields["future"]
                == .object(["value": .integer(1)])
        )
        #expect(
            try await store.dueArtifacts(
                at: failureTime.addingTimeInterval(50),
                kind: .manifest
            ).isEmpty
        )
    }

    @Test
    func interruptedPendingManifestRefreshPreservesRetryState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileSyncStore(rootDirectory: directory)
        let record = try makeRecord()
        _ = try await store.stageDaily(record)
        let daily = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true,
                kind: .daily
            ).first
        )
        try await store.markUploaded(daily)
        let original = try makeTestManifest(for: record)
        _ = try await store.stageManifest(original)
        let manifest = try #require(
            try await store.dueArtifacts(
                at: Date(),
                includeDeferred: true,
                kind: .manifest
            ).first
        )
        try await store.markFailed(
            manifest,
            error: .transient(code: "timedOut"),
            now: Date(timeIntervalSince1970: 1_000),
            randomUnit: 0.5,
            retryPolicy: RetryPolicy()
        )
        let retryBefore = try #require(
            try await store.retryItems().first {
                $0.artifactID == .manifest
            }
        )
        var refreshed = original
        refreshed.lastSuccessfulSyncAt = try ISO8601Timestamp(
            rawValue: "2026-07-23T18:20:00+03:00"
        )
        let refreshedContents = try ExportManifestCodec.encode(refreshed)
        try refreshedContents.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )

        let reopened = try FileSyncStore(rootDirectory: directory)
        try await reopened.recover()
        let retryAfter = try #require(
            try await reopened.retryItems().first {
                $0.artifactID == .manifest
            }
        )
        let recovered = try #require(
            try await reopened.dueArtifacts(
                at: Date(),
                includeDeferred: true,
                kind: .manifest
            ).first
        )

        #expect(retryAfter == retryBefore)
        #expect(recovered.revision == manifest.revision)
        #expect(recovered.contents == refreshedContents)
    }
}

private func makeTestManifest(
    for record: DailyHealthRecord
) throws -> ExportManifest {
    ExportManifest(
        exporterVersion: "1.0.0",
        timeZone: record.timeZone,
        lastSuccessfulSyncAt: try ISO8601Timestamp(
            rawValue: "2026-07-23T18:10:00+03:00"
        ),
        earliestDate: record.date,
        latestDate: record.date,
        recordCount: 1
    )
}

private actor CancellationBarrier {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        let pendingContinuation = continuation
        self.continuation = nil
        pendingContinuation?.resume()
    }
}
