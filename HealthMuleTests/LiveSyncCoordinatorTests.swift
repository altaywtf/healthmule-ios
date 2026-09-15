@preconcurrency import HealthKit
import Foundation
import HealthMuleCore
import XCTest
@testable import HealthMule

final class LiveSyncCoordinatorTests: XCTestCase {
    func testStageFailureDoesNotCommitAnchorsOrSelectionMetadata() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanUp() }
        let provider = CoordinatorRecordProvider(
            records: fixture.records,
            failureDate: fixture.dates[0]
        )
        let events = CoordinatorEventLog()
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            events: events
        )
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: provider,
            events: events
        )

        do {
            _ = try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.stepCount],
                backfillStart: fixture.dates[0]
            )
            XCTFail("Expected the staged record provider to fail.")
        } catch CoordinatorTestError.recordFailure {}

        let committedMetrics = await health.committedMetrics()
        let recordedEvents = await events.snapshot()
        XCTAssertTrue(committedMetrics.isEmpty)
        XCTAssertEqual(
            Array(recordedEvents.prefix(3)),
            [.recover(0), .startDate, .change(.stepCount)]
        )
        XCTAssertFalse(
            recordedEvents.contains {
                if case .commit = $0 {
                    return true
                }
                return false
            }
        )
        XCTAssertNil(
            fixture.defaults.stringArray(
                forKey: "sync.lastStagedMetrics"
            )
        )
        XCTAssertNil(
            fixture.defaults.string(
                forKey: "sync.lastStagedBackfillStart"
            )
        )
        XCTAssertNil(
            fixture.defaults.object(
                forKey: "sync.lastStagedExportContractRevision"
            )
        )
    }

    func testEveryRequestedDateIsDurableBeforeFirstAnchorCommit() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanUp() }
        let provider = CoordinatorRecordProvider(records: fixture.records)
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            stagingRoot: fixture.rootDirectory,
            expectedStagedDates: Set(fixture.dates)
        )
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: provider
        )

        _ = try await coordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [.bodyMass, .stepCount],
            backfillStart: fixture.dates[0]
        )

        let stagedChecks = await health.stagedChecks()
        XCTAssertEqual(stagedChecks.count, 2)
        XCTAssertTrue(stagedChecks.allSatisfy(\.allDatesWereDurable))
        for date in fixture.dates {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.rootDirectory
                        .appendingPathComponent("daily", isDirectory: true)
                        .appendingPathComponent("\(date.rawValue).json")
                        .path
                )
            )
        }
    }

    func testCancelledQueuedReconcileDoesNotLoseFollowingOperation() async throws {
        let fixture = try CoordinatorFixture(dayCount: 1)
        defer { fixture.cleanUp() }
        let provider = CoordinatorRecordProvider(records: fixture.records)
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            blockFirstChange: true
        )
        let queueProbe = CoordinatorQueueProbe()
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: provider,
            queueProbe: queueProbe
        )
        let backfillStart = fixture.dates[0]

        let first = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.bodyMass],
                backfillStart: backfillStart
            )
        }
        await health.waitUntilFirstChangeStarts()

        let cancelled = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.stepCount],
                backfillStart: backfillStart
            )
        }
        await queueProbe.wait(until: 1)
        let following = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.hrvSDNN],
                backfillStart: backfillStart
            )
        }
        await queueProbe.wait(until: 2)
        cancelled.cancel()
        await health.releaseFirstChange()

        _ = try await first.value
        do {
            _ = try await cancelled.value
            XCTFail("Expected the queued reconcile to observe cancellation.")
        } catch is CancellationError {}
        _ = try await following.value

        let changedMetrics = await health.changedMetrics()
        XCTAssertEqual(changedMetrics.first, .bodyMass)
        XCTAssertFalse(changedMetrics.contains(.stepCount))
        XCTAssertTrue(changedMetrics.contains(.hrvSDNN))
    }

    func testConcurrentReconcilesAcquireInFIFOOrder() async throws {
        let fixture = try CoordinatorFixture(dayCount: 1)
        defer { fixture.cleanUp() }
        let provider = CoordinatorRecordProvider(records: fixture.records)
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            blockFirstChange: true
        )
        let queueProbe = CoordinatorQueueProbe()
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: provider,
            queueProbe: queueProbe
        )
        let backfillStart = fixture.dates[0]

        let first = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.bodyMass],
                backfillStart: backfillStart
            )
        }
        await health.waitUntilFirstChangeStarts()

        let second = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.stepCount],
                backfillStart: backfillStart
            )
        }
        await queueProbe.wait(until: 1)
        let third = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.hrvSDNN],
                backfillStart: backfillStart
            )
        }
        await queueProbe.wait(until: 2)
        await health.releaseFirstChange()

        _ = try await first.value
        _ = try await second.value
        _ = try await third.value

        let changedMetrics = await health.changedMetrics()
        XCTAssertEqual(changedMetrics, [.bodyMass, .stepCount, .hrvSDNN])
    }

    func testSuccessfulPassCommitsEveryBatchBeforeFirstUpload() async throws {
        let fixture = try CoordinatorFixture(dayCount: 1)
        defer { fixture.cleanUp() }
        let events = CoordinatorEventLog()
        let provider = CoordinatorRecordProvider(records: fixture.records)
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            events: events
        )
        let destination = CoordinatorDestination(events: events)
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: provider,
            destination: destination,
            events: events
        )

        _ = try await coordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [.bodyMass, .stepCount],
            backfillStart: fixture.dates[0]
        )

        let recordedEvents = await events.snapshot()
        let recoveryIndex = try XCTUnwrap(
            recordedEvents.firstIndex {
                if case .recover = $0 {
                    return true
                }
                return false
            }
        )
        let startIndex = try XCTUnwrap(
            recordedEvents.firstIndex(of: .startDate)
        )
        let firstChangeIndex = try XCTUnwrap(
            recordedEvents.firstIndex {
                if case .change = $0 {
                    return true
                }
                return false
            }
        )
        let stageIndexes = recordedEvents.indices.filter {
            if case .stage = recordedEvents[$0] {
                return true
            }
            return false
        }
        let commitIndexes = recordedEvents.indices.filter {
            if case .commit = recordedEvents[$0] {
                return true
            }
            return false
        }
        let firstUploadIndex = try XCTUnwrap(
            recordedEvents.firstIndex {
                if case .upload = $0 {
                    return true
                }
                return false
            }
        )
        let lastStageIndex = try XCTUnwrap(stageIndexes.last)
        XCTAssertEqual(stageIndexes.count, fixture.dates.count)
        XCTAssertEqual(commitIndexes.count, 2)
        XCTAssertLessThan(recoveryIndex, startIndex)
        XCTAssertLessThan(startIndex, firstChangeIndex)
        XCTAssertLessThan(firstChangeIndex, lastStageIndex)
        XCTAssertTrue(
            commitIndexes.allSatisfy {
                lastStageIndex < $0 && $0 < firstUploadIndex
            }
        )
    }

    func testProgressCoversEmptyOneAndMultipleDayPasses() async throws {
        let emptyFixture = try CoordinatorFixture(dayCount: 1)
        defer { emptyFixture.cleanUp() }
        let emptyLog = SyncProgressLog()
        let emptyCoordinator = try emptyFixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: emptyFixture.startInstant
            ),
            provider: CoordinatorRecordProvider(
                records: emptyFixture.records
            )
        )
        _ = try await emptyCoordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [],
            backfillStart: try LocalDate(rawValue: "2026-07-30"),
            progress: { progress in
                await emptyLog.append(progress)
            }
        )
        let emptyProgress = await emptyLog.snapshot()
        XCTAssertEqual(
            emptyProgress.filter { $0.phase == .staging },
            [
                SyncProgress(
                    phase: .staging,
                    completedUnits: 0,
                    totalUnits: 0,
                    currentDate: nil
                )
            ]
        )

        let oneFixture = try CoordinatorFixture(dayCount: 1)
        defer { oneFixture.cleanUp() }
        let oneLog = SyncProgressLog()
        let oneCoordinator = try oneFixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: oneFixture.startInstant
            ),
            provider: CoordinatorRecordProvider(records: oneFixture.records)
        )
        _ = try await oneCoordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [],
            backfillStart: oneFixture.dates[0],
            progress: { progress in
                await oneLog.append(progress)
            }
        )
        let oneProgress = await oneLog.snapshot()
        XCTAssertEqual(
            oneProgress.filter { $0.phase == .staging },
            [
                SyncProgress(
                    phase: .staging,
                    completedUnits: 0,
                    totalUnits: 1,
                    currentDate: nil
                ),
                SyncProgress(
                    phase: .staging,
                    completedUnits: 1,
                    totalUnits: 1,
                    currentDate: oneFixture.dates[0]
                ),
            ]
        )

        let multipleFixture = try CoordinatorFixture(dayCount: 3)
        defer { multipleFixture.cleanUp() }
        let multipleLog = SyncProgressLog()
        let multipleCoordinator = try multipleFixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: multipleFixture.startInstant
            ),
            provider: CoordinatorRecordProvider(
                records: multipleFixture.records
            )
        )
        _ = try await multipleCoordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [],
            backfillStart: multipleFixture.dates[0],
            progress: { progress in
                await multipleLog.append(progress)
            }
        )
        let multipleProgress = await multipleLog.snapshot()
        XCTAssertEqual(
            multipleProgress.filter { $0.phase == .staging },
            [
                SyncProgress(
                    phase: .staging,
                    completedUnits: 0,
                    totalUnits: 3,
                    currentDate: nil
                ),
                SyncProgress(
                    phase: .staging,
                    completedUnits: 1,
                    totalUnits: 3,
                    currentDate: multipleFixture.dates[0]
                ),
                SyncProgress(
                    phase: .staging,
                    completedUnits: 2,
                    totalUnits: 3,
                    currentDate: multipleFixture.dates[1]
                ),
                SyncProgress(
                    phase: .staging,
                    completedUnits: 3,
                    totalUnits: 3,
                    currentDate: multipleFixture.dates[2]
                ),
            ]
        )
    }

    func testProgressReportsUploadPhaseAfterStaging() async throws {
        let fixture = try CoordinatorFixture(dayCount: 3)
        defer { fixture.cleanUp() }
        let progressLog = SyncProgressLog()
        let coordinator = try fixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: fixture.startInstant
            ),
            provider: CoordinatorRecordProvider(records: fixture.records)
        )

        _ = try await coordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [],
            backfillStart: fixture.dates[0],
            progress: { progress in
                await progressLog.append(progress)
            }
        )

        let progress = await progressLog.snapshot()
        let uploading = progress.filter { $0.phase == .uploading }
        XCTAssertEqual(
            uploading.map(\.completedUnits),
            [0, 1, 2, 3],
            "Every uploaded day must advance the progress bar."
        )
        XCTAssertTrue(uploading.allSatisfy { $0.totalUnits == 3 })
        XCTAssertEqual(progress.last?.phase, .uploading)
        XCTAssertEqual(
            progress.last?.presentationText,
            "Uploading 3 of 3 files"
        )
    }

    func testProgressStopsBeforeFailedDay() async throws {
        let fixture = try CoordinatorFixture(dayCount: 3)
        defer { fixture.cleanUp() }
        let progressLog = SyncProgressLog()
        let coordinator = try fixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: fixture.startInstant
            ),
            provider: CoordinatorRecordProvider(
                records: fixture.records,
                failureDate: fixture.dates[1]
            )
        )

        do {
            _ = try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [],
                backfillStart: fixture.dates[0],
                progress: { progress in
                    await progressLog.append(progress)
                }
            )
            XCTFail("Expected the second day to fail.")
        } catch CoordinatorTestError.recordFailure {}

        let progress = await progressLog.snapshot()
        XCTAssertEqual(
            progress,
            [
                SyncProgress(
                    phase: .staging,
                    completedUnits: 0,
                    totalUnits: 3,
                    currentDate: nil
                ),
                SyncProgress(
                    phase: .staging,
                    completedUnits: 1,
                    totalUnits: 3,
                    currentDate: fixture.dates[0]
                ),
            ]
        )
    }

    func testCancellationAfterMetricReturnStopsQueriesBeforeStagingOrAnchorCommit() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanUp() }
        let health = CoordinatorHealthChanges(
            startDate: fixture.startInstant,
            blockFirstChange: true
        )
        let progressLog = SyncProgressLog()
        let coordinator = try fixture.makeCoordinator(
            health: health,
            provider: CoordinatorRecordProvider(records: fixture.records)
        )
        let backfillStart = fixture.dates[0]
        let task = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [.stepCount, .vo2Max],
                backfillStart: backfillStart,
                progress: { await progressLog.append($0) }
            )
        }

        await health.waitUntilFirstChangeStarts()
        task.cancel()
        await health.releaseFirstChange()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        let changed = await health.changedMetrics()
        let committed = await health.committedMetrics()
        let progress = await progressLog.snapshot()
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(progress.isEmpty)
        XCTAssertNil(fixture.defaults.stringArray(forKey: "sync.lastStagedMetrics"))
    }

    func testCancellationDoesNotCompleteBlockedDay() async throws {
        let fixture = try CoordinatorFixture(dayCount: 3)
        defer { fixture.cleanUp() }
        let provider = CoordinatorRecordProvider(
            records: fixture.records,
            blockingDate: fixture.dates[1]
        )
        let progressLog = SyncProgressLog()
        let coordinator = try fixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: fixture.startInstant
            ),
            provider: provider
        )
        let backfillStart = fixture.dates[0]
        let task = Task {
            try await coordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [],
                backfillStart: backfillStart,
                progress: { progress in
                    await progressLog.append(progress)
                }
            )
        }

        await provider.waitUntilBlocked()
        task.cancel()
        await provider.releaseBlockedRecord()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        let stagingUnits = await progressLog.snapshot()
            .filter { $0.phase == .staging }
            .map(\.completedUnits)
        XCTAssertEqual(stagingUnits, [0, 1])
    }

    func testResumedProgressUsesRemainingDateSet() async throws {
        let fixture = try CoordinatorFixture(dayCount: 5)
        defer { fixture.cleanUp() }
        let failingCoordinator = try fixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: fixture.startInstant
            ),
            provider: CoordinatorRecordProvider(
                records: fixture.records,
                failureDate: fixture.dates[1]
            )
        )
        do {
            _ = try await failingCoordinator.reconcile(
                trigger: .manual,
                enabledMetrics: [],
                backfillStart: fixture.dates[0]
            )
            XCTFail("Expected the initial pass to fail.")
        } catch CoordinatorTestError.recordFailure {}
        fixture.defaults.set([], forKey: "sync.lastStagedMetrics")
        fixture.defaults.set(
            fixture.dates[0].rawValue,
            forKey: "sync.lastStagedBackfillStart"
        )
        fixture.defaults.set(
            2,
            forKey: "sync.lastStagedExportContractRevision"
        )

        let resumedLog = SyncProgressLog()
        let resumedCoordinator = try fixture.makeCoordinator(
            health: CoordinatorHealthChanges(
                startDate: fixture.startInstant
            ),
            provider: CoordinatorRecordProvider(records: fixture.records)
        )
        _ = try await resumedCoordinator.reconcile(
            trigger: .manual,
            enabledMetrics: [],
            backfillStart: fixture.dates[0],
            progress: { progress in
                await resumedLog.append(progress)
            }
        )

        let resumedProgress = await resumedLog.snapshot()
        XCTAssertEqual(resumedProgress.first?.totalUnits, 4)
        XCTAssertEqual(
            resumedProgress.last(where: { $0.phase == .staging })?.completedUnits,
            4
        )
        XCTAssertEqual(
            resumedProgress.last(where: { $0.phase == .staging })?.currentDate,
            fixture.dates[4]
        )
    }
}

private struct CoordinatorFixture {
    let rootDirectory: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let calendar: Calendar
    let now: Date
    let dates: [LocalDate]
    let records: [LocalDate: DailyHealthRecord]
    let startInstant: Date

    init(dayCount: Int = 3) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LiveSyncCoordinatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defaultsSuiteName = "LiveSyncCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar = utcCalendar
        let fixedNow = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29,
                    hour: 12
                )
            )
        )
        now = fixedNow
        let createdDates = try (0..<dayCount).reversed().map { offset in
            let instant = try XCTUnwrap(
                utcCalendar.date(
                    byAdding: .day,
                    value: -offset,
                    to: fixedNow
                )
            )
            let components = utcCalendar.dateComponents(
                [.year, .month, .day],
                from: instant
            )
            return try LocalDate(
                year: try XCTUnwrap(components.year),
                month: try XCTUnwrap(components.month),
                day: try XCTUnwrap(components.day)
            )
        }
        dates = createdDates
        let createdRecords = try Dictionary(
            uniqueKeysWithValues: createdDates.map { date in
                (
                    date,
                    DailyHealthRecord(
                        date: date,
                        timeZone: "UTC",
                        generatedAt: try ISO8601Timestamp(
                            date: fixedNow,
                            timeZone: utcCalendar.timeZone
                        ),
                        metrics: DailyHealthMetrics(steps: 1),
                        workouts: [],
                        totals: WorkoutTotals(
                            workoutMinutes: 0,
                            workoutActiveEnergyKcal: 0
                        ),
                        sources: HealthRecordSources(
                            deviceNames: [],
                            sampleCount: 0
                        )
                    )
                )
            }
        )
        records = createdRecords
        startInstant = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29 - (dayCount - 1)
                )
            )
        )
    }

    func makeCoordinator(
        health: CoordinatorHealthChanges,
        provider: CoordinatorRecordProvider,
        destination: CoordinatorDestination = CoordinatorDestination(),
        queueProbe: CoordinatorQueueProbe? = nil,
        events: CoordinatorEventLog? = nil
    ) throws -> LiveSyncCoordinator {
        let fixedNow = now
        let fixedCalendar = calendar
        return try LiveSyncCoordinator(
            rootDirectory: rootDirectory,
            healthKit: health,
            recordProvider: provider,
            destination: destination,
            diagnostics: DiagnosticsRecorder(),
            defaultsSuiteName: defaultsSuiteName,
            calendar: { fixedCalendar },
            now: { fixedNow },
            operationQueued: { waiterCount in
                queueProbe?.record(waiterCount)
            },
            recordStaged: { date in
                await events?.append(.stage(date))
            }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private final class CoordinatorQueueProbe: @unchecked Sendable {
    private struct Waiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var latestCount = 0
    private var waiters: [Waiter] = []

    func record(_ waiterCount: Int) {
        lock.lock()
        latestCount = max(latestCount, waiterCount)
        let ready = waiters.filter {
            latestCount >= $0.minimumCount
        }
        waiters.removeAll {
            latestCount >= $0.minimumCount
        }
        lock.unlock()

        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(until minimumCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if latestCount >= minimumCount {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(
                Waiter(
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            )
            lock.unlock()
        }
    }
}

private actor CoordinatorRecordProvider: ConfigurableDailyRecordProvider {
    private let records: [LocalDate: DailyHealthRecord]
    private let failureDate: LocalDate?
    private let blockingDate: LocalDate?
    private var didBlock = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(
        records: [LocalDate: DailyHealthRecord],
        failureDate: LocalDate? = nil,
        blockingDate: LocalDate? = nil
    ) {
        self.records = records
        self.failureDate = failureDate
        self.blockingDate = blockingDate
    }

    func configure(
        earliestVO2Date _: Date,
        enabledMetrics _: Set<HealthMetric>
    ) async {}

    func record(for date: LocalDate) async throws -> DailyHealthRecord {
        if date == failureDate {
            throw CoordinatorTestError.recordFailure
        }
        if date == blockingDate {
            didBlock = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        guard let record = records[date] else {
            throw CoordinatorTestError.missingRecord(date.rawValue)
        }
        return record
    }

    func waitUntilBlocked() async {
        guard !didBlock else {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedRecord() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor CoordinatorHealthChanges: HealthChangeTracking {
    struct StagedCheck: Sendable {
        let metric: HealthMetric
        let allDatesWereDurable: Bool
    }

    private let queryStart: Date
    private let stagingRoot: URL?
    private let expectedStagedDates: Set<LocalDate>
    private let events: CoordinatorEventLog?
    private var commits: [HealthMetric] = []
    private var changes: [HealthMetric] = []
    private var checks: [StagedCheck] = []
    private var shouldBlockFirstChange: Bool
    private var firstChangeStarted = false
    private var firstChangeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstChangeContinuation: CheckedContinuation<Void, Never>?

    init(
        startDate: Date,
        stagingRoot: URL? = nil,
        expectedStagedDates: Set<LocalDate> = [],
        events: CoordinatorEventLog? = nil,
        blockFirstChange: Bool = false
    ) {
        queryStart = startDate
        self.stagingRoot = stagingRoot
        self.expectedStagedDates = expectedStagedDates
        self.events = events
        shouldBlockFirstChange = blockFirstChange
    }

    func recoverAuxiliaryState(
        from existingRecords: [DailyHealthRecord]
    ) async throws -> HealthAuxiliaryRecoverySummary {
        await events?.append(.recover(existingRecords.count))
        return HealthAuxiliaryRecoverySummary(
            resetAnchors: false,
            rebuiltBoundaryCount: 0
        )
    }

    func startDate(for _: LocalDate) async throws -> Date {
        await events?.append(.startDate)
        return queryStart
    }

    func changedDates(
        for metric: HealthMetric,
        calendar _: Calendar,
        notBefore _: Date
    ) async throws -> HealthAnchoredChangeBatch {
        changes.append(metric)
        await events?.append(.change(metric))
        if shouldBlockFirstChange {
            shouldBlockFirstChange = false
            firstChangeStarted = true
            let waiters = firstChangeStartWaiters
            firstChangeStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstChangeContinuation = continuation
            }
        }
        return HealthAnchoredChangeBatch(
            metric: metric,
            affectedDates: [],
            anchor: HKQueryAnchor(fromValue: changes.count),
            queryStart: queryStart,
            sampleDates: [:],
            deletedUUIDs: []
        )
    }

    func commit(_ batch: HealthAnchoredChangeBatch) async throws {
        commits.append(batch.metric)
        if let stagingRoot {
            let allDatesWereDurable = expectedStagedDates.allSatisfy { date in
                FileManager.default.fileExists(
                    atPath: stagingRoot
                        .appendingPathComponent("daily", isDirectory: true)
                        .appendingPathComponent("\(date.rawValue).json")
                        .path
                )
            }
            checks.append(
                StagedCheck(
                    metric: batch.metric,
                    allDatesWereDurable: allDatesWereDurable
                )
            )
        }
        await events?.append(.commit(batch.metric))
    }

    func resetAnchors() async {}

    func waitUntilFirstChangeStarts() async {
        if firstChangeStarted {
            return
        }
        await withCheckedContinuation { continuation in
            firstChangeStartWaiters.append(continuation)
        }
    }

    func releaseFirstChange() {
        firstChangeContinuation?.resume()
        firstChangeContinuation = nil
    }

    func committedMetrics() -> [HealthMetric] {
        commits
    }

    func changedMetrics() -> [HealthMetric] {
        changes
    }

    func stagedChecks() -> [StagedCheck] {
        checks
    }
}

private actor CoordinatorDestination: ExportArtifactDestination {
    private let events: CoordinatorEventLog?

    init(events: CoordinatorEventLog? = nil) {
        self.events = events
    }

    func upsert(_ artifact: ExportArtifact) async throws {
        await events?.append(.upload(artifact.id))
    }
}

private actor CoordinatorEventLog {
    enum Event: Equatable, Sendable {
        case recover(Int)
        case startDate
        case change(HealthMetric)
        case stage(LocalDate)
        case commit(HealthMetric)
        case upload(ExportArtifactID)
    }

    private var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}

private actor SyncProgressLog {
    private var values: [SyncProgress] = []

    func append(_ progress: SyncProgress) {
        values.append(progress)
    }

    func snapshot() -> [SyncProgress] {
        values
    }
}

private enum CoordinatorTestError: Error {
    case recordFailure
    case missingRecord(String)
}
