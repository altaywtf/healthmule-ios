import Foundation
import HealthMuleCore

struct LiveSyncOutcome: Sendable {
    let report: SyncReport
    let summary: SyncSummary
}

actor LiveSyncCoordinator {
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private static let stagedMetricsKey = "sync.lastStagedMetrics"
    private static let stagedBackfillStartKey = "sync.lastStagedBackfillStart"
    private static let stagedExportContractRevisionKey =
        "sync.lastStagedExportContractRevision"
    private static let destinationNamespaceKey =
        "sync.destinationAccountNamespace.v1"
    private static let exportContractRevision = 2

    private struct Runtime {
        let store: FileSyncStore
        let engine: SyncEngine
    }

    private let rootDirectory: URL
    private let healthKit: any HealthChangeTracking
    private let recordProvider: any ConfigurableDailyRecordProvider
    private let destination: any ExportArtifactDestination
    private let diagnostics: DiagnosticsRecorder
    private let defaults: UserDefaults
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private let operationQueued: (@Sendable (Int) -> Void)?
    private let recordStaged: (@Sendable (LocalDate) async -> Void)?
    private var runtime: Runtime
    private var lastSuccessfulSyncAt: Date?
    private var lastStagedMetrics: Set<HealthMetric>?
    private var lastStagedBackfillStart: LocalDate?
    private var lastStagedExportContractRevision: Int?
    private var destinationNamespace: String?
    private var activeOperationID: UUID?
    private var operationWaiters: [OperationWaiter] = []

    init(
        rootDirectory: URL,
        healthKit: any HealthChangeTracking,
        recordProvider: any ConfigurableDailyRecordProvider,
        destination: any ExportArtifactDestination,
        diagnostics: DiagnosticsRecorder,
        defaultsSuiteName: String? = nil,
        calendar: @escaping @Sendable () -> Calendar = {
            LocalDayCalendar.current
        },
        now: @escaping @Sendable () -> Date = { .now },
        operationQueued: (@Sendable (Int) -> Void)? = nil,
        recordStaged: (@Sendable (LocalDate) async -> Void)? = nil
    ) throws {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        self.rootDirectory = rootDirectory
        self.healthKit = healthKit
        self.recordProvider = recordProvider
        self.destination = destination
        self.diagnostics = diagnostics
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.operationQueued = operationQueued
        self.recordStaged = recordStaged
        lastSuccessfulSyncAt = defaults.object(
            forKey: "sync.lastSuccessful"
        ) as? Date
        lastStagedMetrics = defaults.stringArray(
            forKey: Self.stagedMetricsKey
        ).map { Set($0.compactMap(HealthMetric.init(rawValue:))) }
        lastStagedBackfillStart = defaults.string(
            forKey: Self.stagedBackfillStartKey
        ).flatMap { try? LocalDate(rawValue: $0) }
        lastStagedExportContractRevision = defaults.object(
            forKey: Self.stagedExportContractRevisionKey
        ) as? Int
        destinationNamespace = defaults.string(
            forKey: Self.destinationNamespaceKey
        )
        runtime = try Self.makeRuntime(
            rootDirectory: rootDirectory,
            recordProvider: recordProvider,
            destination: destination
        )
    }

    func prepare() async throws {
        try await runtime.store.recover()
    }

    func reconcile(
        trigger: SyncTrigger,
        enabledMetrics: Set<HealthMetric>,
        backfillStart: LocalDate,
        progress: (@Sendable (SyncProgress) async -> Void)? = nil
    ) async throws -> LiveSyncOutcome {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        let syncCalendar = calendar()
        let currentDate = now()
        let backfillStartDate = backfillStart
        let missingDates = try await missingBackfillDates(
            from: backfillStartDate,
            through: currentDate,
            calendar: syncCalendar
        )
        let exportContractChanged =
            lastStagedExportContractRevision != Self.exportContractRevision
        if
            trigger == .retry,
            lastStagedMetrics == enabledMetrics,
            lastStagedBackfillStart == backfillStartDate,
            !exportContractChanged,
            missingDates.isEmpty
        {
            let report = try await runtime.engine.retryPendingUploads(
                force: true,
                progress: Self.uploadProgressObserver(forwardingTo: progress)
            )
            return try await outcome(report: report)
        }

        let existingRecords = try await runtime.store.allDailyRecords()
        _ = try await healthKit.recoverAuxiliaryState(
            from: existingRecords
        )
        let backfillStartInstant = try await healthKit.startDate(
            for: backfillStartDate
        )
        var dates = try BackfillDatePlanner.recentDates(
            through: currentDate,
            count: 3,
            notBefore: backfillStartDate,
            calendar: syncCalendar
        )
        var batches: [HealthAnchoredChangeBatch] = []
        let existingDates = Set(existingRecords.map(\.date))
        let historyStart = Self.effectiveHistoryStart(
            requestedStart: backfillStartInstant,
            existingRecordDates: existingRecords.map(\.date)
        )
        await recordProvider.configure(
            earliestVO2Date: historyStart,
            enabledMetrics: enabledMetrics
        )
        let selectionChanged = lastStagedMetrics != enabledMetrics
        let backfillBoundaryChanged =
            lastStagedBackfillStart != backfillStartDate
        if selectionChanged || backfillBoundaryChanged || exportContractChanged {
            dates.formUnion(existingDates)
        }

        if trigger != .rebuild {
            for metric in HealthMetric.allCases where enabledMetrics.contains(metric) {
                try Task.checkCancellation()
                let batch = try await healthKit.changedDates(
                    for: metric,
                    calendar: syncCalendar,
                    notBefore: backfillStartInstant
                )
                try Task.checkCancellation()
                batches.append(batch)
                let changedDates = try localDates(from: batch.affectedDates)
                dates.formUnion(
                    changedDates.filter {
                        $0 >= backfillStartDate || existingDates.contains($0)
                    }
                )

                if metric == .vo2Max, !batch.affectedDates.isEmpty {
                    dates.formUnion(existingDates)
                }
            }
            dates.formUnion(missingDates)
        }

        var report = try await stage(
            dates: dates,
            progress: progress
        )
        if selectionChanged {
            persistStagedMetrics(enabledMetrics)
        }
        if backfillBoundaryChanged {
            persistStagedBackfillStart(backfillStartDate)
        }
        if exportContractChanged {
            try await runtime.store.enqueueCurrentDailyArtifactsForUpload()
            persistStagedExportContractRevision()
        }
        for batch in batches {
            try await healthKit.commit(batch)
        }

        let uploadReport = try await runtime.engine.retryPendingUploads(
            force: trigger == .retry,
            progress: Self.uploadProgressObserver(forwardingTo: progress)
        )
        merge(uploadReport, into: &report)
        return try await outcome(report: report)
    }

    private static func uploadProgressObserver(
        forwardingTo progress: (@Sendable (SyncProgress) async -> Void)?
    ) -> UploadProgressObserver? {
        guard let progress else { return nil }
        return { uploadProgress in
            await progress(
                SyncProgress(
                    phase: .uploading,
                    completedUnits: uploadProgress.settledArtifacts,
                    totalUnits: uploadProgress.totalArtifacts,
                    currentDate: nil
                )
            )
        }
    }

    func stageObservedChange(
        metric: HealthMetric,
        enabledMetrics: Set<HealthMetric>,
        backfillStart: LocalDate
    ) async throws {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        guard enabledMetrics.contains(metric) else { return }
        let syncCalendar = calendar()
        let currentDate = now()
        let selectionChanged = lastStagedMetrics != enabledMetrics
        let backfillStartDate = backfillStart
        let existingRecords = try await runtime.store.allDailyRecords()
        _ = try await healthKit.recoverAuxiliaryState(
            from: existingRecords
        )
        let backfillStartInstant = try await healthKit.startDate(
            for: backfillStartDate
        )
        let backfillBoundaryChanged =
            lastStagedBackfillStart != backfillStartDate
        let exportContractChanged =
            lastStagedExportContractRevision != Self.exportContractRevision
        let batch = try await healthKit.changedDates(
            for: metric,
            calendar: syncCalendar,
            notBefore: backfillStartInstant
        )
        var dates = try BackfillDatePlanner.recentDates(
            through: currentDate,
            count: 3,
            notBefore: backfillStartDate,
            calendar: syncCalendar
        )
        let existingDates = Set(existingRecords.map(\.date))
        let historyStart = Self.effectiveHistoryStart(
            requestedStart: backfillStartInstant,
            existingRecordDates: existingRecords.map(\.date)
        )
        await recordProvider.configure(
            earliestVO2Date: historyStart,
            enabledMetrics: enabledMetrics
        )
        if selectionChanged || backfillBoundaryChanged || exportContractChanged {
            dates.formUnion(existingDates)
        }
        let changedDates = try localDates(from: batch.affectedDates)
        dates.formUnion(
            changedDates.filter {
                $0 >= backfillStartDate || existingDates.contains($0)
            }
        )
        dates.formUnion(
            try await missingBackfillDates(
                from: backfillStartDate,
                through: currentDate,
                calendar: syncCalendar
            )
        )
        if metric == .vo2Max, !batch.affectedDates.isEmpty {
            dates.formUnion(existingDates)
        }

        _ = try await stage(dates: dates)
        if selectionChanged {
            persistStagedMetrics(enabledMetrics)
        }
        if backfillBoundaryChanged {
            persistStagedBackfillStart(backfillStartDate)
        }
        if exportContractChanged {
            try await runtime.store.enqueueCurrentDailyArtifactsForUpload()
            persistStagedExportContractRevision()
        }
        try await healthKit.commit(batch)
    }

    func flushPendingUploads() async throws -> LiveSyncOutcome {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        let report = try await runtime.engine.retryPendingUploads()
        return try await outcome(report: report)
    }

    func resumeAfterReauthorization() async throws -> LiveSyncOutcome {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        let report = try await runtime.engine.resumeAfterReauthorization()
        return try await outcome(report: report)
    }

    func waitUntilIdle() async {
        do {
            let operationID = try await acquireOperation()
            releaseOperation(id: operationID)
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected operation acquisition error: \(error)")
        }
    }

    func prepareDestination(
        destinationNamespace newDestinationNamespace: String
    ) async throws -> SyncSummary {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        if destinationNamespace != newDestinationNamespace {
            try await runtime.store.resetRemoteUploadState()
            lastSuccessfulSyncAt = nil
            defaults.removeObject(forKey: "sync.lastSuccessful")
            destinationNamespace = newDestinationNamespace
            defaults.set(
                newDestinationNamespace,
                forKey: Self.destinationNamespaceKey
            )
        }
        return try await summary()
    }

    func summary() async throws -> SyncSummary {
        let records = try await runtime.store.allDailyRecords()
        let retryItems = try await runtime.store.retryItems()
        return SyncSummary(
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestExportedDate: records.map(\.date).max()?.rawValue,
            pendingUploadCount: retryItems.count,
            retryableUploadCount: retryItems.count {
                $0.blockReason == nil
            },
            permanentFailureCount: retryItems.count {
                $0.blockReason == .permanentFailure
            }
        )
    }

    func reset() async throws {
        let operationID = try await acquireOperation()
        defer { releaseOperation(id: operationID) }

        try await healthKit.resetAnchors()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.removeItem(at: rootDirectory)
        }
        runtime = try Self.makeRuntime(
            rootDirectory: rootDirectory,
            recordProvider: recordProvider,
            destination: destination
        )
        lastSuccessfulSyncAt = nil
        lastStagedMetrics = nil
        lastStagedBackfillStart = nil
        lastStagedExportContractRevision = nil
        Self.clearPersistedResetMetadata(defaults: defaults)
    }

    static func clearPersistedResetMetadata(
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: "sync.lastSuccessful")
        defaults.removeObject(forKey: Self.stagedMetricsKey)
        defaults.removeObject(
            forKey: Self.stagedBackfillStartKey
        )
        defaults.removeObject(
            forKey: Self.stagedExportContractRevisionKey
        )
    }

    private func stage(
        dates: Set<LocalDate>,
        progress: (@Sendable (SyncProgress) async -> Void)? = nil
    ) async throws -> SyncReport {
        let sortedDates = dates.sorted()
        await progress?(
            SyncProgress(
                phase: .staging,
                completedUnits: 0,
                totalUnits: sortedDates.count,
                currentDate: nil
            )
        )
        try await runtime.store.recover()
        var report = SyncReport()
        for (index, date) in sortedDates.enumerated() {
            try Task.checkCancellation()
            let record = try await recordProvider.record(for: date)
            try Task.checkCancellation()
            switch try await runtime.store.stageDaily(record) {
            case .staged:
                report.stagedDailyCount += 1
            case .unchanged:
                report.unchangedDailyCount += 1
            }
            try Task.checkCancellation()
            await progress?(
                SyncProgress(
                    phase: .staging,
                    completedUnits: index + 1,
                    totalUnits: sortedDates.count,
                    currentDate: date
                )
            )
            await recordStaged?(date)
        }
        report.pendingUploadCount = try await runtime.store.pendingUploadCount()
        return report
    }

    private func outcome(report: SyncReport) async throws -> LiveSyncOutcome {
        if report.manifestUploaded {
            lastSuccessfulSyncAt = now()
            defaults.set(
                lastSuccessfulSyncAt,
                forKey: "sync.lastSuccessful"
            )
        }
        let summary = try await summary()
        await diagnostics.record(
            .syncCoreReport(DiagnosticCoreReport(report))
        )
        return LiveSyncOutcome(report: report, summary: summary)
    }

    private func missingBackfillDates(
        from startDate: LocalDate,
        through endDate: Date,
        calendar: Calendar
    ) async throws -> Set<LocalDate> {
        let existingDates = Set(
            try await runtime.store.allDailyRecords().map(\.date)
        )
        return try BackfillDatePlanner.missingDates(
            from: startDate,
            through: endDate,
            excluding: existingDates,
            calendar: calendar
        )
    }

    private func localDates(from values: Set<String>) throws -> Set<LocalDate> {
        try Set(values.map(LocalDate.init(rawValue:)))
    }

    static func effectiveHistoryStart(
        requestedStart: Date,
        existingRecordDates _: [LocalDate]
    ) -> Date {
        // Older artifacts can remain repair targets after a range is narrowed,
        // but they must never widen R4's active VO2 carry-forward window.
        requestedStart
    }

    private func merge(_ source: SyncReport, into destination: inout SyncReport) {
        destination.stagedDailyCount += source.stagedDailyCount
        destination.unchangedDailyCount += source.unchangedDailyCount
        destination.uploadedDailyCount += source.uploadedDailyCount
        destination.manifestUploaded =
            destination.manifestUploaded || source.manifestUploaded
        destination.failures.append(contentsOf: source.failures)
        destination.pendingUploadCount = source.pendingUploadCount
    }

    private func persistStagedMetrics(_ metrics: Set<HealthMetric>) {
        lastStagedMetrics = metrics
        defaults.set(
            metrics.map(\.rawValue).sorted(),
            forKey: Self.stagedMetricsKey
        )
    }

    private func persistStagedBackfillStart(_ date: LocalDate) {
        lastStagedBackfillStart = date
        defaults.set(
            date.rawValue,
            forKey: Self.stagedBackfillStartKey
        )
    }

    private func persistStagedExportContractRevision() {
        lastStagedExportContractRevision = Self.exportContractRevision
        defaults.set(
            Self.exportContractRevision,
            forKey: Self.stagedExportContractRevisionKey
        )
    }

    private func acquireOperation() async throws -> UUID {
        try Task.checkCancellation()
        let waiterID = UUID()
        if activeOperationID == nil {
            activeOperationID = waiterID
            return waiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operationWaiters.append(
                    OperationWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
                operationQueued?(operationWaiters.count)
            }
        } onCancel: {
            Task {
                await self.cancelOperationWaiter(id: waiterID)
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            releaseOperation(id: waiterID)
            throw error
        }
        return waiterID
    }

    private func cancelOperationWaiter(id: UUID) {
        guard let index = operationWaiters.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseOperation(id: UUID) {
        precondition(
            activeOperationID == id,
            "Only the active operation can release the coordinator."
        )
        guard !operationWaiters.isEmpty else {
            activeOperationID = nil
            return
        }
        let next = operationWaiters.removeFirst()
        activeOperationID = next.id
        next.continuation.resume()
    }

    private static func makeRuntime(
        rootDirectory: URL,
        recordProvider: any ConfigurableDailyRecordProvider,
        destination: any ExportArtifactDestination
    ) throws -> Runtime {
        let store = try FileSyncStore(rootDirectory: rootDirectory)
        let engine = SyncEngine(
            configuration: SyncEngine.Configuration(
                exporterVersion: Bundle.main.infoDictionary?[
                    "CFBundleShortVersionString"
                ] as? String ?? "1.0.0"
            ),
            recordProvider: recordProvider,
            destination: destination,
            store: store
        )
        return Runtime(store: store, engine: engine)
    }
}
