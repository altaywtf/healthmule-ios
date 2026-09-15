import Foundation
import HealthMuleCore
import Observation

private enum AppModelStorageError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "Local protected sync storage is unavailable: \(message)"
        }
    }
}

private struct SyncActivityResult: Equatable, Sendable {
    let outcome: SyncActivityOutcome
    let reason: SyncActivityReason?
}

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .home
    private(set) var initialLoadPhase: InitialLoadPhase = .loading
    private var syncProgressState = SyncProgressState()
    var syncProgress: SyncProgress? {
        syncProgressState.progress
    }
    private(set) var operationOrigin: OperationOrigin = .userInitiated
    var operationState: OperationState = .idle {
        didSet {
            if case .working = operationState {
                operationEpoch &+= 1
                syncProgressState.clear()
            } else if oldValue != operationState {
                syncProgressState.clear()
            }
            publishCompanionStatus()
        }
    }
    var presentedOperationState: OperationState {
        operationState.presented(for: operationOrigin)
    }
    var googleConnection: GoogleConnectionState {
        didSet {
            if oldValue != googleConnection {
                googleTransitionEpoch &+= 1
            }
            publishCompanionStatus()
        }
    }
    var metricStatuses: [MetricStatus]
    private var backgroundDeliveryRegistrationState =
        BackgroundDeliveryRegistrationState()
    var syncSummary: SyncSummary {
        didSet {
            publishCompanionStatus()
        }
    }
    private(set) var syncActivitySummary: SyncActivitySummary = .empty
    var backfillRange: BackfillRange
    var customBackfillStart: Date {
        BackfillDateCodec.date(from: customBackfillStartValue)
            ?? BackfillRange.thirtyDays.startDate(customDate: .now)
    }
    var enabledMetrics: Set<HealthMetric>
    var diagnosticsURL: URL?
    var isHealthKitAvailable: Bool
    var healthAuthorizationState: HealthAuthorizationState {
        didSet {
            publishCompanionStatus()
        }
    }

    let googleConfiguration: GoogleOAuthConfiguration

    var syncReadiness: SyncReadiness {
        SyncReadiness.resolve(
            health: healthAuthorizationState,
            google: googleConnection,
            localStorageAvailable:
                syncCoordinator != nil && syncInitializationError == nil
        )
    }

    var backgroundDeliveryAdvisory: BackgroundDeliveryAdvisory? {
        BackgroundDeliveryAdvisory(
            failedMetrics:
                backgroundDeliveryRegistrationState.failedEnabledMetrics
        )
    }

    private let googleAuth: GoogleAuthService
    private let driveClient: DriveAPIClient
    private let healthKit: HealthKitClient
    private let diagnostics: DiagnosticsRecorder
    private let syncActivityStore: SyncActivityStore
    private let stagingRoot: URL
    private var syncCoordinator: LiveSyncCoordinator?
    private var syncInitializationError: String?
    private var googleTransitionEpoch: UInt64 = 0
    private var activeDriveActivation: DriveAccountActivation?
    private var healthRefreshEpoch: UInt64 = 0
    private var operationEpoch: UInt64 = 0
    private var selectionReconciliationQueue = SelectionReconciliationQueue()
    private var reconcileOccupancy = ReconcileOccupancy()
    private var observerFlushQueue = ObserverFlushQueue()
    private var observerStagingFailurePending = false
    private var watchConnectivity: PhoneWatchConnectivityCoordinator?
    private let isUITesting: Bool
    // The calendar date is authoritative; `Date` is only a live UI projection.
    private var customBackfillStartValue: String
    private var selectedBackfillStart: String
    private var isBootstrapped = false
    private var bootstrapInProgress = false
    private var bootstrapRequestedTrigger: SyncTrigger?
    private var bootstrapActiveTrigger: SyncTrigger?
    private var bootstrapWaiters: [
        CheckedContinuation<SyncTrigger, Never>
    ] = []

    private init(
        googleConfiguration: GoogleOAuthConfiguration,
        googleAuth: GoogleAuthService,
        driveClient: DriveAPIClient,
        healthKit: HealthKitClient,
        diagnostics: DiagnosticsRecorder,
        syncActivityStore: SyncActivityStore,
        stagingRoot: URL,
        syncCoordinator: LiveSyncCoordinator?,
        syncInitializationError: String?,
        isUITesting: Bool
    ) {
        self.googleConfiguration = googleConfiguration
        self.googleAuth = googleAuth
        self.driveClient = driveClient
        self.healthKit = healthKit
        self.diagnostics = diagnostics
        self.syncActivityStore = syncActivityStore
        self.stagingRoot = stagingRoot
        self.syncCoordinator = syncCoordinator
        self.syncInitializationError = syncInitializationError
        self.isUITesting = isUITesting

        googleConnection = googleConfiguration.isConfigured
            ? .restoring
            : .notConfigured
        let initialHealthState: HealthAuthorizationState = healthKit.isAvailable
            ? .checking
            : .unavailable
        let storedEnabledMetrics = Self.loadEnabledMetrics()
        enabledMetrics = storedEnabledMetrics
        metricStatuses = HealthMetric.allCases.map {
            MetricStatus(
                metric: $0,
                state: storedEnabledMetrics.contains($0)
                    ? (healthKit.isAvailable ? .checking : .unavailable)
                    : .notIncluded
            )
        }
        syncSummary = .empty
        let storedBackfillRange = BackfillRange(
            rawValue: UserDefaults.standard.string(forKey: "backfill.range") ?? ""
        ) ?? .thirtyDays
        let localCalendar = LocalDayCalendar.current
        let defaultCustomStart = localCalendar.date(
            byAdding: .day,
            value: -29,
            to: localCalendar.startOfDay(for: .now)
        ) ?? .now
        let storedCustomStartValue = UserDefaults.standard.string(
            forKey: "backfill.customStart"
        ).flatMap { value in
            BackfillDateCodec.date(from: value).map { _ in value }
        } ?? (UserDefaults.standard.object(
            forKey: "backfill.customStart"
        ) as? Date).map {
            BackfillDateCodec.string(from: $0)
        } ?? BackfillDateCodec.string(from: defaultCustomStart)
        let storedCustomStart = BackfillDateCodec.date(
            from: storedCustomStartValue
        ) ?? defaultCustomStart
        backfillRange = storedBackfillRange
        customBackfillStartValue = storedCustomStartValue
        selectedBackfillStart = UserDefaults.standard.string(
            forKey: "backfill.selectedStart"
        ) ?? UserDefaults.standard.string(
            forKey: "sync.lastStagedBackfillStart"
        ) ?? (UserDefaults.standard.object(
            forKey: "backfill.selectedStart"
        ) as? Date).map {
            BackfillDateCodec.string(from: $0)
        } ?? BackfillDateCodec.string(
            from: storedBackfillRange.startDate(
                customDate: storedCustomStart
            )
        )
        isHealthKitAvailable = healthKit.isAvailable
        healthAuthorizationState = initialHealthState
        UserDefaults.standard.set(
            storedCustomStartValue,
            forKey: "backfill.customStart"
        )
        UserDefaults.standard.set(
            selectedBackfillStart,
            forKey: "backfill.selectedStart"
        )
    }

    static func live() -> AppModel {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let configuration = GoogleOAuthConfiguration.bundled()
        let googleAuth = GoogleAuthService(configuration: configuration)
        let healthKit = HealthKitClient()
        let diagnostics = DiagnosticsRecorder()
        let applicationSupportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("HealthMule", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("HealthMule", isDirectory: true)
        let stagingRoot = applicationSupportRoot.appendingPathComponent(
            "Staging",
            isDirectory: true
        )
        let metadataStore = DriveMetadataStore(
            directoryURL: stagingRoot.appendingPathComponent(
                "drive-metadata",
                isDirectory: true
            )
        )
        let driveClient = DriveAPIClient(
            tokenProvider: { accountID in
                try await googleAuth.accessToken(for: accountID)
            },
            metadataStore: metadataStore,
            uploadTransport: BackgroundDriveUploadTransport.shared
        )
        let syncActivityStore = SyncActivityStore(
            directoryURL: applicationSupportRoot.appendingPathComponent(
                "Activity",
                isDirectory: true
            )
        )
        let recordProvider = HealthKitDailyRecordProvider(healthKit: healthKit)
        let syncCoordinator: LiveSyncCoordinator?
        let syncInitializationError: String?
        do {
            syncCoordinator = try LiveSyncCoordinator(
                rootDirectory: stagingRoot,
                healthKit: healthKit,
                recordProvider: recordProvider,
                destination: DriveArtifactDestination(driveClient: driveClient),
                diagnostics: diagnostics
            )
            syncInitializationError = nil
        } catch {
            syncCoordinator = nil
            syncInitializationError = error.localizedDescription
        }
        let model = AppModel(
            googleConfiguration: configuration,
            googleAuth: googleAuth,
            driveClient: driveClient,
            healthKit: healthKit,
            diagnostics: diagnostics,
            syncActivityStore: syncActivityStore,
            stagingRoot: stagingRoot,
            syncCoordinator: syncCoordinator,
            syncInitializationError: syncInitializationError,
            isUITesting: isUITesting
        )
        model.activateWatchConnectivity()
        return model
    }

    private func activateWatchConnectivity() {
        guard !isUITesting, watchConnectivity == nil else { return }
        let coordinator = PhoneWatchConnectivityCoordinator(
            snapshotProvider: { [weak self] in
                self.map { model in
                    CompanionSnapshotFactory.make(
                        readiness: model.syncReadiness,
                        operationState: model.operationState,
                        summary: model.syncSummary
                    )
                }
            },
            syncRequestHandler: { [weak self] in
                await self?.reconcile(trigger: .watchCompanion)
            }
        )
        watchConnectivity = coordinator
        coordinator.activate()
    }

    private func publishCompanionStatus() {
        watchConnectivity?.publishCurrentStatus()
    }

    private func setOperationState(
        _ state: OperationState,
        origin: OperationOrigin
    ) {
        operationOrigin = origin
        operationState = state
    }

    func bootstrap() async {
        _ = await bootstrap(reconciliationTrigger: .appLaunch)
    }

    @discardableResult
    private func bootstrap(
        reconciliationTrigger requestedTrigger: SyncTrigger
    ) async -> SyncTrigger? {
        guard !isUITesting else {
            loadUITestState()
            isBootstrapped = true
            if !ProcessInfo.processInfo.arguments.contains(
                "--ui-initial-loading"
            ) {
                finishInitialLoad()
            }
            return requestedTrigger
        }
        if isBootstrapped {
            return nil
        }
        if bootstrapInProgress {
            if
                requestedTrigger == .backgroundRefresh,
                bootstrapActiveTrigger == nil
            {
                bootstrapRequestedTrigger = Self.preferredBootstrapTrigger(
                    current: bootstrapRequestedTrigger,
                    requested: requestedTrigger
                )
            }
            return await withCheckedContinuation { continuation in
                bootstrapWaiters.append(continuation)
            }
        }
        bootstrapInProgress = true
        bootstrapRequestedTrigger = requestedTrigger
        await registerHealthObservers()

        await diagnostics.record(.bootstrapStarted)
        await refreshSyncActivitySummary()
        await recoverSyncCoordinatorIfNeeded()
        let restoredGoogleCredentials =
            await restoreGoogleConnection() != nil
            && googleConnection.isAuthorized
        var credentialRestoreEpoch: UInt64?
        if googleConnection.isAuthorized {
            let isDriveReady = await refreshDriveFolder(
                operationOrigin: .automatic
            )
            if restoredGoogleCredentials, isDriveReady {
                credentialRestoreEpoch = googleTransitionEpoch
            }
        }
        if let syncCoordinator {
            syncSummary = (try? await syncCoordinator.summary()) ?? .empty
        }
        await Self.refreshHealthBeforeCredentialReplay(
            refreshHealth: { [self] in
                await refreshHealthConnectionState(
                    publishingCheckingState: !operationState.isWorking
                )
            },
            resumeDrive: { [self] in
                guard let credentialRestoreEpoch else { return }
                await resumeCredentialReplay(
                    expectedEpoch: credentialRestoreEpoch
                )
            }
        )

        let reconciliationTrigger = bootstrapRequestedTrigger
            ?? requestedTrigger
        bootstrapActiveTrigger = reconciliationTrigger
        await reconcile(trigger: reconciliationTrigger)
        await scheduleBackgroundRefresh()
        await diagnostics.record(.bootstrapFinished)
        isBootstrapped = true
        finishInitialLoad()
        bootstrapInProgress = false
        bootstrapRequestedTrigger = nil
        bootstrapActiveTrigger = nil
        let waiters = bootstrapWaiters
        bootstrapWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: reconciliationTrigger)
        }
        return reconciliationTrigger
    }

    private func finishInitialLoad() {
        guard initialLoadPhase == .loading else { return }
        initialLoadPhase = .loaded
    }

    func applicationDidBecomeActive() async {
        guard !isUITesting else { return }
        let wasBootstrapped = isBootstrapped
        await bootstrap()
        guard wasBootstrapped else { return }
        await recoverSyncCoordinatorIfNeeded()
        var restoredGoogleCredentials = false
        var credentialRestoreEpoch: UInt64?
        if
            case .temporarilyUnavailable = googleConnection,
            !operationState.isWorking
        {
            if let syncCoordinator {
                await syncCoordinator.waitUntilIdle()
            }
            guard
                !operationState.isWorking,
                case .temporarilyUnavailable = googleConnection
            else {
                return
            }
            restoredGoogleCredentials =
                await restoreGoogleConnection() != nil
                && googleConnection.isAuthorized
        }
        if
            googleConnection.isAuthorized,
            !operationState.isWorking
        {
            let isDriveReady = await refreshDriveFolder(
                operationOrigin: .automatic
            )
            if restoredGoogleCredentials, isDriveReady {
                credentialRestoreEpoch = googleTransitionEpoch
            }
        }
        await Self.refreshHealthBeforeCredentialReplay(
            refreshHealth: { [self] in
                await refreshHealthConnectionState(
                    publishingCheckingState: !operationState.isWorking
                )
            },
            resumeDrive: { [self] in
                guard let credentialRestoreEpoch else { return }
                await resumeCredentialReplay(
                    expectedEpoch: credentialRestoreEpoch
                )
            }
        )
        await reconcile(trigger: .foreground)
        await scheduleBackgroundRefresh()
    }

    func performBackgroundRefresh() async {
        let bootstrapTrigger = await bootstrap(
            reconciliationTrigger: .backgroundRefresh
        )
        if Self.backgroundRefreshRequiresFollowUp(
            afterBootstrap: bootstrapTrigger
        ) {
            await reconcile(trigger: .backgroundRefresh)
        }
        if Self.backgroundRefreshRequiresScheduling(
            afterBootstrap: bootstrapTrigger
        ) {
            await scheduleBackgroundRefresh()
        }
    }

    static func preferredBootstrapTrigger(
        current: SyncTrigger?,
        requested: SyncTrigger
    ) -> SyncTrigger {
        if current == .backgroundRefresh || requested == .backgroundRefresh {
            return .backgroundRefresh
        }
        return current ?? requested
    }

    static func backgroundRefreshRequiresFollowUp(
        afterBootstrap trigger: SyncTrigger?
    ) -> Bool {
        trigger != .backgroundRefresh
    }

    static func backgroundRefreshRequiresScheduling(
        afterBootstrap trigger: SyncTrigger?
    ) -> Bool {
        trigger == nil
    }

    func scheduleBackgroundRefresh() async {
        let result = await BackgroundRefreshCoordinator.schedule()
        do {
            try await syncActivityStore.recordSchedule(result)
            syncActivitySummary = try await syncActivityStore.snapshot()
        } catch let error as SyncActivityStoreError {
            await diagnostics.record(.syncActivityStoreFailed(error))
        } catch {
            await diagnostics.record(.syncActivityStoreFailed(.writeFailed))
        }
        await diagnostics.record(.backgroundRefreshSchedule(result))
    }

    func requestHealthAuthorization() async {
        setOperationState(
            .working(
                .healthAuthorization,
                "Requesting Apple Health access"
            ),
            origin: .userInitiated
        )
        let expectedOperationEpoch = operationEpoch
        do {
            let registrationSummary = try await healthKit.requestAuthorization(
                for: enabledMetrics
            )
            guard operationEpoch == expectedOperationEpoch else {
                return
            }
            applyBackgroundDeliverySummary(registrationSummary)
            await refreshHealthStatuses()
            guard operationEpoch == expectedOperationEpoch else {
                return
            }
            await registerHealthObservers()
            operationState = .succeeded(
                .healthAuthorization,
                "Apple Health request complete. Apple does not report which read permissions were approved."
            )
            await diagnostics.record(.healthRequestCompleted)
            await reconcileAfterSetupIfReady()
        } catch {
            guard operationEpoch == expectedOperationEpoch else {
                return
            }
            operationState = .failed(
                .healthAuthorization,
                error.localizedDescription
            )
            await diagnostics.record(
                .healthRequestFailed(DiagnosticErrorCode(capturing: error))
            )
        }
    }

    func retryHealthStatus() async {
        let checkingState = OperationState.working(
            .healthAuthorization,
            "Checking Apple Health"
        )
        setOperationState(checkingState, origin: .userInitiated)
        let expectedOperationEpoch = operationEpoch
        await refreshHealthStatuses()
        await registerHealthObservers()
        let registrationSummary = await healthKit.updateBackgroundDelivery(
            for: enabledMetrics
        )
        guard
            operationEpoch == expectedOperationEpoch,
            operationState == checkingState
        else {
            return
        }
        applyBackgroundDeliverySummary(registrationSummary)
        if case .statusUnavailable = healthAuthorizationState {
            operationState = .failed(
                .healthAuthorization,
                "Apple Health status could not be refreshed. Try again after reopening the app."
            )
            return
        }
        operationState = .succeeded(
            .healthAuthorization,
            "Apple Health status was refreshed."
        )
        await reconcileAfterSetupIfReady()
    }

    func connectGoogle() async {
        let connectingState = OperationState.working(
            .googleConnection,
            "Connecting Google"
        )
        setOperationState(connectingState, origin: .userInitiated)
        let expectedOperationEpoch = operationEpoch
        var expectedEpoch = beginGoogleTransition()
        if let syncCoordinator {
            await syncCoordinator.waitUntilIdle()
        }
        guard
            operationEpoch == expectedOperationEpoch,
            operationState == connectingState,
            isGoogleTransitionCurrent(expectedEpoch)
        else {
            return
        }
        do {
            let authorizedConnection = try await googleAuth.connect()
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == connectingState
            else {
                return
            }
            googleConnection = authorizedConnection
            expectedEpoch = googleTransitionEpoch
            guard try await configureDriveFolders(
                expectedEpoch: expectedEpoch
            ) else {
                if
                    isGoogleTransitionCurrent(expectedEpoch),
                    operationEpoch == expectedOperationEpoch
                {
                    settleGoogleOperation(
                        ifCurrent: connectingState,
                        expectedEpoch: expectedOperationEpoch
                    )
                }
                return
            }
            expectedEpoch = googleTransitionEpoch
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                googleConnection.isDriveReady,
                operationEpoch == expectedOperationEpoch,
                operationState == connectingState
            else {
                return
            }
            if let syncCoordinator {
                let outcome = try await syncCoordinator.resumeAfterReauthorization()
                guard
                    isGoogleTransitionCurrent(expectedEpoch),
                    operationEpoch == expectedOperationEpoch,
                    operationState == connectingState
                else {
                    return
                }
                syncSummary = outcome.summary
                let requiresReconnect = await requireGoogleReconnect(
                    for: outcome.report,
                    expectedEpoch: expectedEpoch
                )
                if requiresReconnect {
                    if
                        operationEpoch == expectedOperationEpoch,
                        operationState == connectingState
                    {
                        operationState = .failed(
                            .googleConnection,
                            Self.googleReconnectMessage
                        )
                    }
                    return
                }
                guard isGoogleTransitionCurrent(expectedEpoch) else {
                    return
                }
            }
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == connectingState
            else {
                return
            }
            operationState = .succeeded(
                .googleConnection,
                "Google Drive is connected."
            )
            await diagnostics.record(.googleConnected)
            await reconcileAfterSetupIfReady()
        } catch {
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == connectingState
            else {
                return
            }
            let isLocalStorageFailure = error is AppModelStorageError
            let requiresReconnect = isLocalStorageFailure
                ? false
                : await requireGoogleReconnect(
                    for: error,
                    expectedEpoch: expectedEpoch
                )
            let markedUnavailable: Bool
            if requiresReconnect || isLocalStorageFailure {
                markedUnavailable = false
            } else if error is DriveAPIError {
                markedUnavailable = await markDriveUnavailableIfNeeded(
                    expectedEpoch: expectedEpoch
                )
            } else {
                markedUnavailable = false
            }
            if
                operationEpoch == expectedOperationEpoch,
                operationState == connectingState,
                requiresReconnect
                    || markedUnavailable
                    || isGoogleTransitionCurrent(expectedEpoch)
            {
                operationState = .failed(
                    .googleConnection,
                    error.localizedDescription
                )
            }
            await diagnostics.record(
                .googleConnectFailed(DiagnosticErrorCode(capturing: error))
            )
        }
    }

    func disconnectGoogle() async {
        let disconnectingState = OperationState.working(
            .googleConnection,
            "Disconnecting Google"
        )
        setOperationState(disconnectingState, origin: .userInitiated)
        let expectedOperationEpoch = operationEpoch
        let expectedEpoch = beginGoogleTransition()
        let expectedActivation = activeDriveActivation
        if let syncCoordinator {
            await syncCoordinator.waitUntilIdle()
        }
        guard
            operationEpoch == expectedOperationEpoch,
            operationState == disconnectingState,
            isGoogleTransitionCurrent(expectedEpoch)
        else {
            return
        }
        do {
            try await googleAuth.disconnect()
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == disconnectingState
            else {
                return
            }
            if let expectedActivation {
                try await driveClient.clearActiveAccount(
                    ifMatching: expectedActivation
                )
            }
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == disconnectingState,
                activeDriveActivation == expectedActivation
            else {
                return
            }
            activeDriveActivation = nil
            googleConnection = googleConfiguration.isConfigured
                ? .disconnected
                : .notConfigured
            operationState = .succeeded(
                .googleConnection,
                "Google was disconnected. Drive files were kept."
            )
            await diagnostics.record(.googleDisconnected)
        } catch {
            guard
                isGoogleTransitionCurrent(expectedEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == disconnectingState
            else {
                return
            }
            operationState = .failed(.googleConnection, error.localizedDescription)
        }
    }

    func reconcile(trigger: SyncTrigger) async {
        if operationState.isWorking || !reconcileOccupancy.admit() {
            selectionReconciliationQueue.enqueue(trigger)
            let activityID = await beginSyncActivity(trigger: trigger)
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .operationInProgress
            )
            return
        }
        defer { reconcileOccupancy.release() }

        var nextTrigger = trigger
        while true {
            // A full reconciliation consumes the selections visible at its
            // start. A later settings change remains queued while the actor is
            // suspended and causes one serialized follow-up pass.
            selectionReconciliationQueue.beginPass()
            await reconcileOnce(trigger: nextTrigger)
            guard
                let followUpTrigger =
                    selectionReconciliationQueue.followUpTrigger,
                !operationState.isWorking
            else {
                return
            }
            nextTrigger = followUpTrigger
        }
    }

    private func reconcileOnce(trigger: SyncTrigger) async {
        let activityID = await beginSyncActivity(trigger: trigger)
        guard !operationState.isWorking else {
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .operationInProgress
            )
            return
        }
        guard healthAuthorizationState.allowsQueries else {
            if trigger == .manual {
                setOperationState(
                    .failed(
                        .sync,
                        "Complete the Apple Health request in Setup first."
                    ),
                    origin: trigger.operationOrigin
                )
            }
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .healthNotReady
            )
            return
        }
        guard googleConnection.isDriveReady else {
            if trigger == .manual {
                setOperationState(
                    .failed(
                        .sync,
                        "Finish connecting Google Drive in Setup first."
                    ),
                    origin: trigger.operationOrigin
                )
            }
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .driveNotReady
            )
            return
        }
        guard let syncCoordinator else {
            setOperationState(
                .failed(
                    .sync,
                    syncInitializationError
                        ?? "Local protected sync storage could not be prepared."
                ),
                origin: trigger.operationOrigin
            )
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .localStorageUnavailable
            )
            return
        }

        let syncingState = OperationState.working(
            .sync,
            trigger == .rebuild ? "Rebuilding the last three days" : "Syncing"
        )
        setOperationState(syncingState, origin: trigger.operationOrigin)
        let expectedOperationEpoch = operationEpoch
        syncProgressState.begin(epoch: expectedOperationEpoch)
        let expectedGoogleEpoch = googleTransitionEpoch
        let clock = ContinuousClock()
        let startedAt = clock.now
        await diagnostics.record(.syncStarted(trigger))

        do {
            let backfillStart = try resolvedBackfillStart()
            let queryableMetrics = await healthKit.queryableMetrics(
                from: enabledMetrics
            )
            let outcome = try await syncCoordinator.reconcile(
                trigger: trigger,
                enabledMetrics: queryableMetrics,
                backfillStart: backfillStart,
                progress: { [weak self] progress in
                    await self?.publishSyncProgress(
                        progress,
                        expectedOperationEpoch: expectedOperationEpoch,
                        expectedOperationState: syncingState
                    )
                }
            )
            let activityCounts = SyncActivityCounts(
                staged: outcome.report.stagedDailyCount,
                uploaded: outcome.report.uploadedDailyCount,
                pending: outcome.summary.pendingUploadCount,
                failed: outcome.report.failures.count
            )
            guard
                isGoogleTransitionCurrent(expectedGoogleEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == syncingState
            else {
                settleStaleOperation(
                    ifCurrent: syncingState,
                    expectedEpoch: expectedOperationEpoch
                )
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded,
                    counts: activityCounts
                )
                return
            }
            syncSummary = outcome.summary
            await refreshHealthStatuses(publishingCheckingState: false)
            guard
                isGoogleTransitionCurrent(expectedGoogleEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == syncingState
            else {
                settleStaleOperation(
                    ifCurrent: syncingState,
                    expectedEpoch: expectedOperationEpoch
                )
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded,
                    counts: activityCounts
                )
                return
            }
            let duration = startedAt.duration(to: clock.now)
            let requiresReconnect = await requireGoogleReconnect(
                for: outcome.report,
                expectedEpoch: expectedGoogleEpoch
            )
            guard
                operationEpoch == expectedOperationEpoch,
                operationState == syncingState
            else {
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded,
                    counts: activityCounts
                )
                return
            }
            if requiresReconnect {
                operationState = .failed(
                    .sync,
                    Self.googleReconnectMessage
                )
                await finishSyncActivity(
                    activityID,
                    outcome: .failed,
                    reason: .googleReauthorizationRequired,
                    counts: activityCounts
                )
            } else if Self.driveDestinationChanged(in: outcome.report) {
                _ = await markDriveUnavailableIfNeeded(
                    expectedEpoch: expectedGoogleEpoch
                )
                guard
                    operationEpoch == expectedOperationEpoch,
                    operationState == syncingState
                else {
                    await finishSyncActivity(
                        activityID,
                        outcome: .skipped,
                        reason: .superseded,
                        counts: activityCounts
                    )
                    return
                }
                operationState = .failed(
                    .sync,
                    "The managed Drive folder changed. Verify it in Setup before retrying; local copies are safe."
                )
                await finishSyncActivity(
                    activityID,
                    outcome: .failed,
                    reason: .driveDestinationChanged,
                    counts: activityCounts
                )
            } else {
                guard
                    isGoogleTransitionCurrent(expectedGoogleEpoch),
                    operationEpoch == expectedOperationEpoch,
                    operationState == syncingState
                else {
                    settleStaleOperation(
                        ifCurrent: syncingState,
                        expectedEpoch: expectedOperationEpoch
                    )
                    await finishSyncActivity(
                        activityID,
                        outcome: .skipped,
                        reason: .superseded,
                        counts: activityCounts
                    )
                    return
                }
                operationState = Self.syncCompletionState(
                    report: outcome.report,
                    summary: syncSummary
                )
                let activityResult = Self.syncActivityResult(
                    report: outcome.report,
                    summary: syncSummary
                )
                await finishSyncActivity(
                    activityID,
                    outcome: activityResult.outcome,
                    reason: activityResult.reason,
                    counts: activityCounts
                )
            }
            await diagnostics.record(
                .syncFinished(
                    durationMilliseconds: Int(
                        duration.components.seconds * 1_000
                    ),
                    failureCount: outcome.report.failures.count,
                    pendingCount: syncSummary.pendingUploadCount,
                    stagedCount: outcome.report.stagedDailyCount,
                    uploadedCount: outcome.report.uploadedDailyCount
                )
            )
        } catch {
            guard
                isGoogleTransitionCurrent(expectedGoogleEpoch),
                operationEpoch == expectedOperationEpoch,
                operationState == syncingState
            else {
                settleStaleOperation(
                    ifCurrent: syncingState,
                    expectedEpoch: expectedOperationEpoch
                )
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded
                )
                return
            }
            let requiresReconnect = await requireGoogleReconnect(
                for: error,
                expectedEpoch: expectedGoogleEpoch
            )
            guard
                operationEpoch == expectedOperationEpoch,
                operationState == syncingState,
                requiresReconnect
                    || isGoogleTransitionCurrent(expectedGoogleEpoch)
            else {
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded
                )
                return
            }
            operationState = .failed(
                .sync,
                error.localizedDescription
            )
            await diagnostics.record(
                .syncFailed(DiagnosticErrorCode(capturing: error))
            )
            await finishSyncActivity(
                activityID,
                outcome: .failed,
                reason: requiresReconnect
                    ? .googleReauthorizationRequired
                    : .reconcileFailed
            )
        }
    }

    func retryFailedUploads() async {
        await reconcile(trigger: .retry)
    }

    private func refreshSyncActivitySummary() async {
        do {
            syncActivitySummary = try await syncActivityStore.snapshot()
        } catch let error as SyncActivityStoreError {
            await diagnostics.record(.syncActivityStoreFailed(error))
        } catch {
            await diagnostics.record(.syncActivityStoreFailed(.invalidState))
        }
    }

    private func beginSyncActivity(trigger: SyncTrigger) async -> UUID? {
        do {
            let id = try await syncActivityStore.begin(trigger: trigger)
            syncActivitySummary = try await syncActivityStore.snapshot()
            return id
        } catch let error as SyncActivityStoreError {
            await diagnostics.record(.syncActivityStoreFailed(error))
            return nil
        } catch {
            await diagnostics.record(.syncActivityStoreFailed(.writeFailed))
            return nil
        }
    }

    private func finishSyncActivity(
        _ id: UUID?,
        outcome: SyncActivityOutcome,
        reason: SyncActivityReason? = nil,
        counts: SyncActivityCounts = .zero
    ) async {
        guard let id else { return }
        do {
            try await syncActivityStore.finish(
                id: id,
                outcome: outcome,
                reason: reason,
                counts: counts
            )
            syncActivitySummary = try await syncActivityStore.snapshot()
        } catch let error as SyncActivityStoreError {
            await diagnostics.record(.syncActivityStoreFailed(error))
        } catch {
            await diagnostics.record(.syncActivityStoreFailed(.writeFailed))
        }
    }

    private static func syncActivityResult(
        report: SyncReport,
        summary: SyncSummary
    ) -> SyncActivityResult {
        if summary.permanentFailureCount > 0 || !report.failures.isEmpty {
            return SyncActivityResult(
                outcome: .failed,
                reason: .reconcileFailed
            )
        }
        if summary.pendingUploadCount > 0 {
            return SyncActivityResult(outcome: .pending, reason: nil)
        }
        return SyncActivityResult(outcome: .succeeded, reason: nil)
    }

    private func publishSyncProgress(
        _ progress: SyncProgress,
        expectedOperationEpoch: UInt64,
        expectedOperationState: OperationState
    ) {
        guard operationState == expectedOperationState else {
            return
        }
        syncProgressState.publish(
            progress,
            epoch: expectedOperationEpoch
        )
    }

    func retryGoogleRestore() async {
        let restoringState = OperationState.working(
            .googleConnection,
            "Restoring Google connection"
        )
        setOperationState(restoringState, origin: .userInitiated)
        let expectedOperationEpoch = operationEpoch
        if let syncCoordinator {
            await syncCoordinator.waitUntilIdle()
        }
        guard
            operationEpoch == expectedOperationEpoch,
            operationState == restoringState
        else {
            return
        }
        guard
            await restoreGoogleConnection() != nil,
            operationEpoch == expectedOperationEpoch,
            operationState == restoringState
        else {
            return
        }
        if googleConnection.isAuthorized {
            let restoredEpoch = googleTransitionEpoch
            guard
                await refreshDriveFolder(
                    expectedEpoch: restoredEpoch,
                    operationOrigin: .userInitiated
                ),
                googleConnection.isDriveReady,
                operationEpoch == expectedOperationEpoch,
                operationState == restoringState
            else {
                settleGoogleOperation(
                    ifCurrent: restoringState,
                    expectedEpoch: expectedOperationEpoch
                )
                return
            }
            let connectedEpoch = googleTransitionEpoch
            _ = await resumeAfterCredentialRestore(
                expectedEpoch: connectedEpoch
            )
            guard
                googleConnection.isDriveReady,
                operationEpoch == expectedOperationEpoch,
                operationState == restoringState
            else {
                settleGoogleOperation(
                    ifCurrent: restoringState,
                    expectedEpoch: expectedOperationEpoch
                )
                return
            }
            operationState = .succeeded(
                .googleConnection,
                "Google Drive connection was restored."
            )
            await reconcileAfterSetupIfReady()
        } else if case .temporarilyUnavailable = googleConnection {
            operationState = .failed(
                .googleConnection,
                "Google could not be reached yet. HealthMule will retry when the app becomes active again."
            )
        } else if case .reauthorizationRequired = googleConnection {
            operationState = .failed(
                .googleConnection,
                Self.googleReconnectMessage
            )
        } else {
            operationState = .failed(
                .googleConnection,
                "Connect Google Drive to continue."
            )
        }
    }

    func rebuildLastThreeDays() async {
        await reconcile(trigger: .rebuild)
    }

    func updateBackfillRange(_ range: BackfillRange) {
        guard backfillRange != range else { return }
        backfillRange = range
        UserDefaults.standard.set(range.rawValue, forKey: "backfill.range")
        if range == .custom {
            setSelectedBackfillStart(customBackfillStartValue)
        } else {
            setSelectedBackfillStart(
                range.startDate(customDate: customBackfillStart)
            )
        }
        queueHistorySelectionReconciliation()
    }

    func updateCustomBackfillStart(_ date: Date) {
        let nextDate = BackfillDateCodec.string(from: date)
        guard customBackfillStartValue != nextDate else { return }
        customBackfillStartValue = nextDate
        UserDefaults.standard.set(
            nextDate,
            forKey: "backfill.customStart"
        )
        if backfillRange == .custom {
            setSelectedBackfillStart(nextDate)
            queueHistorySelectionReconciliation()
        }
    }

    func setMetric(_ metric: HealthMetric, enabled: Bool) {
        let selectionChanged: Bool
        if enabled {
            selectionChanged = enabledMetrics.insert(metric).inserted
        } else {
            selectionChanged = enabledMetrics.remove(metric) != nil
        }
        guard selectionChanged else { return }
        selectionReconciliationQueue.enqueue(.metricSelection)
        UserDefaults.standard.set(
            enabledMetrics.map(\.rawValue).sorted(),
            forKey: "metrics.enabled"
        )
        metricStatuses = metricStatuses.map { status in
            guard enabledMetrics.contains(status.metric) else {
                return MetricStatus(
                    metric: status.metric,
                    state: .notIncluded
                )
            }
            if status.metric == metric, status.state == .notIncluded {
                return MetricStatus(metric: status.metric, state: .checking)
            }
            return status
        }
        guard !isUITesting else { return }
        Task { [weak self] in
            await self?.applyHealthMetricSelection()
        }
    }

    func prepareDiagnosticsExport() async {
        guard !operationState.isWorking else {
            return
        }
        let preparingState = OperationState.working(
            .diagnostics,
            "Preparing diagnostics"
        )
        setOperationState(preparingState, origin: .userInitiated)
        let expectedOperationEpoch = operationEpoch
        do {
            diagnosticsURL = try await diagnostics.export()
            guard
                operationEpoch == expectedOperationEpoch,
                operationState == preparingState
            else {
                return
            }
            operationState = .succeeded(
                .diagnostics,
                "Diagnostics are ready to share."
            )
        } catch {
            guard
                operationEpoch == expectedOperationEpoch,
                operationState == preparingState
            else {
                return
            }
            operationState = .failed(
                .diagnostics,
                "Diagnostics could not be prepared."
            )
        }
    }

    func resetLocalState() async {
        setOperationState(
            .working(
                .localReset,
                "Resetting local sync state"
            ),
            origin: .userInitiated
        )
        do {
            let candidate = if let syncCoordinator {
                syncCoordinator
            } else {
                try makeSyncCoordinator()
            }
            try await candidate.reset()
            let refreshedSummary = try await candidate.summary()
            syncCoordinator = candidate
            syncInitializationError = nil
            syncSummary = refreshedSummary
            diagnosticsURL = nil
            operationState = .succeeded(
                .localReset,
                "Local sync history was reset. Drive files and their stable IDs were kept."
            )
            await diagnostics.record(.localReset)
        } catch {
            syncCoordinator = nil
            syncInitializationError = error.localizedDescription
            operationState = .failed(
                .localReset,
                error.localizedDescription
            )
        }
    }

    private func refreshHealthStatuses(
        publishingCheckingState: Bool = true
    ) async {
        healthRefreshEpoch &+= 1
        let refreshEpoch = healthRefreshEpoch
        isHealthKitAvailable = healthKit.isAvailable
        if !isHealthKitAvailable {
            healthAuthorizationState = .unavailable
            metricStatuses = HealthMetric.allCases.map {
                MetricStatus(
                    metric: $0,
                    state: enabledMetrics.contains($0)
                        ? .unavailable
                        : .notIncluded
                )
            }
            return
        }
        if publishingCheckingState {
            healthAuthorizationState = .checking
            metricStatuses = HealthMetric.allCases.map {
                MetricStatus(
                    metric: $0,
                    state: enabledMetrics.contains($0)
                        ? .checking
                        : .notIncluded
                )
            }
        }
        let refreshedState = await healthKit.authorizationState(
            for: enabledMetrics
        )
        guard healthRefreshEpoch == refreshEpoch else {
            return
        }
        let refreshedStatuses = await healthKit.metricStatuses(
            for: refreshedState,
            enabledMetrics: enabledMetrics
        )
        guard healthRefreshEpoch == refreshEpoch else {
            return
        }
        if healthAuthorizationState != refreshedState {
            healthAuthorizationState = refreshedState
        }
        if metricStatuses != refreshedStatuses {
            metricStatuses = refreshedStatuses
        }
    }

    static func refreshHealthBeforeCredentialReplay(
        refreshHealth: @MainActor () async -> Void,
        resumeDrive: @MainActor () async -> Void
    ) async {
        await refreshHealth()
        await resumeDrive()
    }

    private func refreshHealthConnectionState(
        publishingCheckingState: Bool
    ) async {
        await refreshHealthStatuses(
            publishingCheckingState: publishingCheckingState
        )
        await registerHealthObservers()
        let registrationSummary = await healthKit.updateBackgroundDelivery(
            for: enabledMetrics
        )
        applyBackgroundDeliverySummary(registrationSummary)
    }

    @discardableResult
    private func restoreGoogleConnection() async -> UInt64? {
        _ = beginGoogleTransition()
        let expectedActivation = activeDriveActivation
        googleConnection = googleConfiguration.isConfigured
            ? .restoring
            : .notConfigured
        let restoringEpoch = googleTransitionEpoch
        if let expectedActivation {
            do {
                try await driveClient.clearActiveAccount(
                    ifMatching: expectedActivation
                )
            } catch {
                guard isGoogleTransitionCurrent(restoringEpoch) else {
                    return nil
                }
                activeDriveActivation = nil
                googleConnection = .temporarilyUnavailable
                return nil
            }
            guard
                isGoogleTransitionCurrent(restoringEpoch),
                activeDriveActivation == expectedActivation
            else {
                return nil
            }
            activeDriveActivation = nil
        }
        guard googleConfiguration.isConfigured else {
            return restoringEpoch
        }
        do {
            let restoredConnection = try await googleAuth.restore()
            guard isGoogleTransitionCurrent(restoringEpoch) else {
                return nil
            }
            googleConnection = restoredConnection
            return googleTransitionEpoch
        } catch let error as GoogleAuthError {
            guard isGoogleTransitionCurrent(restoringEpoch) else {
                return nil
            }
            let terminalEpoch: UInt64?
            switch error {
            case
                .identityUnavailable,
                .reauthorizationRequired,
                .scopeNotGranted,
                .signedOut:
                if await markGoogleReconnectRequired(
                    expectedEpoch: restoringEpoch
                ) {
                    terminalEpoch = googleTransitionEpoch
                } else {
                    terminalEpoch = nil
                }
            case .accountChanged, .refreshTemporarilyUnavailable:
                googleConnection = .temporarilyUnavailable
                terminalEpoch = googleTransitionEpoch
            case .configurationMissing:
                googleConnection = .notConfigured
                terminalEpoch = googleTransitionEpoch
            case .presenterUnavailable:
                googleConnection = .disconnected
                terminalEpoch = googleTransitionEpoch
            }
            await diagnostics.record(
                .googleRestoreFailed(DiagnosticErrorCode(capturing: error))
            )
            guard
                let terminalEpoch,
                isGoogleTransitionCurrent(terminalEpoch)
            else {
                return nil
            }
            return terminalEpoch
        } catch {
            guard isGoogleTransitionCurrent(restoringEpoch) else {
                return nil
            }
            googleConnection = .temporarilyUnavailable
            let terminalEpoch = googleTransitionEpoch
            await diagnostics.record(
                .googleRestoreFailed(DiagnosticErrorCode(capturing: error))
            )
            return isGoogleTransitionCurrent(terminalEpoch)
                ? terminalEpoch
                : nil
        }
    }

    private func registerHealthObservers() async {
        await healthKit.registerObservers(
            for: enabledMetrics
        ) { [weak self] metric in
            await self?.handleHealthObservation(metric)
        }
    }

    private func applyHealthMetricSelection() async {
        await refreshHealthStatuses(
            publishingCheckingState: !operationState.isWorking
        )
        await registerHealthObservers()
        var appliedMetrics = enabledMetrics
        while true {
            let registrationSummary = await healthKit.updateBackgroundDelivery(
                for: appliedMetrics
            )
            guard appliedMetrics != enabledMetrics else {
                applyBackgroundDeliverySummary(registrationSummary)
                break
            }
            appliedMetrics = enabledMetrics
        }
        await reconcile(trigger: .metricSelection)
    }

    private func applyBackgroundDeliverySummary(
        _ summary: BackgroundDeliveryRegistrationSummary
    ) {
        backgroundDeliveryRegistrationState.apply(summary)
    }

    private func queueHistorySelectionReconciliation() {
        selectionReconciliationQueue.enqueue(.historySelection)
        guard !isUITesting else { return }
        Task { [weak self] in
            await self?.reconcile(trigger: .historySelection)
        }
    }

    private func reconcileAfterSetupIfReady() async {
        guard
            healthAuthorizationState.allowsQueries,
            googleConnection.isDriveReady
        else {
            return
        }
        await reconcile(trigger: .manual)
    }

    @discardableResult
    private func resumeAfterCredentialRestore(
        expectedEpoch: UInt64
    ) async -> Bool {
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            googleConnection.isDriveReady,
            let syncCoordinator
        else {
            return false
        }
        do {
            let outcome = try await syncCoordinator.resumeAfterReauthorization()
            guard isGoogleTransitionCurrent(expectedEpoch) else {
                return false
            }
            syncSummary = outcome.summary
            if await requireGoogleReconnect(
                for: outcome.report,
                expectedEpoch: expectedEpoch
            ) {
                return false
            }
            if Self.driveDestinationChanged(in: outcome.report) {
                _ = await markDriveUnavailableIfNeeded(
                    expectedEpoch: expectedEpoch
                )
                return false
            }
            return isGoogleTransitionCurrent(expectedEpoch)
        } catch {
            guard isGoogleTransitionCurrent(expectedEpoch) else {
                return false
            }
            _ = await requireGoogleReconnect(
                for: error,
                expectedEpoch: expectedEpoch
            )
            await diagnostics.record(
                .credentialRestoreResumeFailed(
                    DiagnosticErrorCode(capturing: error)
                )
            )
            return false
        }
    }

    private func resumeCredentialReplay(expectedEpoch: UInt64) async {
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            googleConnection.isDriveReady
        else {
            return
        }
        let progressState: OperationState?
        let progressEpoch: UInt64?
        if syncSummary.pendingUploadCount > 0, !operationState.isWorking {
            let state = OperationState.working(
                .sync,
                "Resuming pending uploads"
            )
            setOperationState(state, origin: .automatic)
            progressState = state
            progressEpoch = operationEpoch
        } else {
            progressState = nil
            progressEpoch = nil
        }

        _ = await resumeAfterCredentialRestore(expectedEpoch: expectedEpoch)

        if let progressState, let progressEpoch {
            settleStaleOperation(
                ifCurrent: progressState,
                expectedEpoch: progressEpoch
            )
        }
    }

    private func makeSyncCoordinator() throws -> LiveSyncCoordinator {
        let recordProvider = HealthKitDailyRecordProvider(
            healthKit: healthKit
        )
        return try LiveSyncCoordinator(
            rootDirectory: stagingRoot,
            healthKit: healthKit,
            recordProvider: recordProvider,
            destination: DriveArtifactDestination(
                driveClient: driveClient
            ),
            diagnostics: diagnostics
        )
    }

    private func recoverSyncCoordinatorIfNeeded() async {
        defer {
            publishCompanionStatus()
        }
        let wasUnavailable =
            syncCoordinator == nil || syncInitializationError != nil
        do {
            let candidate = if let syncCoordinator {
                syncCoordinator
            } else {
                try makeSyncCoordinator()
            }
            try await candidate.prepare()
            syncCoordinator = candidate
            syncInitializationError = nil
            if wasUnavailable {
                await diagnostics.record(.localStorageRestored)
            }
        } catch {
            syncInitializationError = error.localizedDescription
            syncCoordinator = nil
            await diagnostics.record(
                .localStorageRestoreFailed(
                    DiagnosticErrorCode(capturing: error)
                )
            )
        }
    }

    @discardableResult
    private func refreshDriveFolder(
        expectedEpoch: UInt64? = nil,
        operationOrigin: OperationOrigin
    ) async -> Bool {
        let folderEpoch = expectedEpoch ?? googleTransitionEpoch
        let folderOperationEpoch = operationEpoch
        guard isGoogleTransitionCurrent(folderEpoch) else {
            return false
        }
        do {
            let configured = try await configureDriveFolders(
                expectedEpoch: folderEpoch
            )
            if
                configured,
                operationEpoch == folderOperationEpoch,
                operationState.isFailure(.googleConnection)
            {
                operationState = .idle
            }
            return configured
        } catch {
            guard isGoogleTransitionCurrent(folderEpoch) else {
                return false
            }
            let isLocalStorageFailure = error is AppModelStorageError
            let requiresReconnect = isLocalStorageFailure
                ? false
                : await requireGoogleReconnect(
                    for: error,
                    expectedEpoch: folderEpoch
                )
            if
                !requiresReconnect,
                !isLocalStorageFailure,
                error is DriveAPIError
            {
                _ = await markDriveUnavailableIfNeeded(
                    expectedEpoch: folderEpoch
                )
            }
            if operationEpoch == folderOperationEpoch,
               !operationState.isWorking
            {
                setOperationState(
                    .failed(
                        .googleConnection,
                        error.localizedDescription
                    ),
                    origin: operationOrigin
                )
            }
            return false
        }
    }

    private func configureDriveFolders(
        expectedEpoch: UInt64
    ) async throws -> Bool {
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            let expectedAccount = googleConnection.account
        else {
            return false
        }
        let folder = try await driveClient.ensureAppFolders(
            for: expectedAccount.id
        )
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            let currentAccount = googleConnection.account,
            currentAccount.id == expectedAccount.id
        else {
            return false
        }
        if let syncCoordinator {
            let preparedSummary: SyncSummary
            do {
                preparedSummary = try await syncCoordinator.prepareDestination(
                    destinationNamespace: DriveMetadataStore.destinationNamespace(
                        for: currentAccount.id,
                        rootID: folder.rootID,
                        dailyID: folder.dailyID
                    )
                )
            } catch {
                guard isGoogleTransitionCurrent(expectedEpoch) else {
                    return false
                }
                syncInitializationError = error.localizedDescription
                throw AppModelStorageError.unavailable(
                    error.localizedDescription
                )
            }
            guard isGoogleTransitionCurrent(expectedEpoch) else {
                return false
            }
            syncSummary = preparedSummary
            syncInitializationError = nil
        }
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            let verifiedAccount = googleConnection.account,
            verifiedAccount.id == currentAccount.id
        else {
            return false
        }
        let activation = try await driveClient.activateAccount(
            verifiedAccount.id,
            folders: folder
        )
        guard isGoogleTransitionCurrent(expectedEpoch) else {
            try await driveClient.clearActiveAccount(ifMatching: activation)
            return false
        }
        activeDriveActivation = activation
        _ = beginGoogleTransition()
        googleConnection = .connected(
            GoogleConnection(
                account: verifiedAccount,
                folderID: folder.rootID,
                folderName: folder.name
            )
        )
        return true
    }

    private static func loadEnabledMetrics() -> Set<HealthMetric> {
        guard let stored = UserDefaults.standard.stringArray(
            forKey: "metrics.enabled"
        ) else {
            return Set(HealthMetric.allCases)
        }
        return Set(stored.compactMap(HealthMetric.init(rawValue:)))
    }

    private func handleHealthObservation(_ metric: HealthMetric) async {
        guard healthAuthorizationState.allowsQueries, let syncCoordinator else {
            return
        }
        do {
            let backfillStart = try resolvedBackfillStart()
            let queryableMetrics = await healthKit.queryableMetrics(
                from: enabledMetrics
            )
            try await syncCoordinator.stageObservedChange(
                metric: metric,
                enabledMetrics: queryableMetrics,
                backfillStart: backfillStart
            )
            publishSyncSummaryIfChanged(
                try await syncCoordinator.summary()
            )
            requestObserverFlush()
        } catch {
            await diagnostics.record(
                .observerStagingFailed(
                    DiagnosticErrorCode(capturing: error)
                )
            )
            requestObserverFlush(stagingFailed: true)
        }
    }

    private func requestObserverFlush(stagingFailed: Bool = false) {
        observerStagingFailurePending =
            observerStagingFailurePending || stagingFailed
        guard observerFlushQueue.request() else {
            return
        }
        Task { [weak self] in
            await self?.drainObserverFlushes()
        }
    }

    private func drainObserverFlushes() async {
        while observerFlushQueue.beginPass() {
            await performObserverFlushPass()
        }
        observerFlushQueue.finish()
    }

    private func performObserverFlushPass() async {
        let activityID = await beginSyncActivity(trigger: .healthObserver)
        let hadStagingFailure = observerStagingFailurePending
        observerStagingFailurePending = false
        guard let syncCoordinator else {
            await finishSyncActivity(
                activityID,
                outcome: .skipped,
                reason: .localStorageUnavailable
            )
            return
        }
        guard googleConnection.isDriveReady else {
            await finishSyncActivity(
                activityID,
                outcome: hadStagingFailure ? .failed : .skipped,
                reason: hadStagingFailure
                    ? .observerStagingFailed
                    : .driveNotReady
            )
            return
        }
        guard !operationState.isWorking(.googleConnection) else {
            await finishSyncActivity(
                activityID,
                outcome: hadStagingFailure ? .failed : .skipped,
                reason: hadStagingFailure
                    ? .observerStagingFailed
                    : .operationInProgress
            )
            return
        }
        let expectedGoogleEpoch = googleTransitionEpoch
        do {
            let outcome = try await syncCoordinator.flushPendingUploads()
            let activityCounts = SyncActivityCounts(
                staged: outcome.report.stagedDailyCount,
                uploaded: outcome.report.uploadedDailyCount,
                pending: outcome.summary.pendingUploadCount,
                failed: max(
                    outcome.report.failures.count,
                    hadStagingFailure ? 1 : 0
                )
            )
            guard isGoogleTransitionCurrent(expectedGoogleEpoch) else {
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded,
                    counts: activityCounts
                )
                return
            }
            publishSyncSummaryIfChanged(outcome.summary)
            let requiresReconnect = await requireGoogleReconnect(
                for: outcome.report,
                expectedEpoch: expectedGoogleEpoch
            )
            if requiresReconnect {
                publishObserverSyncCompletionIfAppropriate(outcome)
                await finishSyncActivity(
                    activityID,
                    outcome: .failed,
                    reason: .googleReauthorizationRequired,
                    counts: activityCounts
                )
                return
            }
            if Self.driveDestinationChanged(in: outcome.report) {
                let markedUnavailable = await markDriveUnavailableIfNeeded(
                    expectedEpoch: expectedGoogleEpoch
                )
                if markedUnavailable {
                    publishObserverSyncCompletionIfAppropriate(outcome)
                }
                await finishSyncActivity(
                    activityID,
                    outcome: .failed,
                    reason: .driveDestinationChanged,
                    counts: activityCounts
                )
                return
            }
            guard isGoogleTransitionCurrent(expectedGoogleEpoch) else {
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded,
                    counts: activityCounts
                )
                return
            }
            publishObserverSyncCompletionIfAppropriate(outcome)
            let result = hadStagingFailure
                ? SyncActivityResult(
                    outcome: .failed,
                    reason: .observerStagingFailed
                )
                : Self.syncActivityResult(
                    report: outcome.report,
                    summary: outcome.summary
                )
            await finishSyncActivity(
                activityID,
                outcome: result.outcome,
                reason: result.reason,
                counts: activityCounts
            )
        } catch {
            guard isGoogleTransitionCurrent(expectedGoogleEpoch) else {
                await finishSyncActivity(
                    activityID,
                    outcome: .skipped,
                    reason: .superseded
                )
                return
            }
            _ = await requireGoogleReconnect(
                for: error,
                expectedEpoch: expectedGoogleEpoch
            )
            await diagnostics.record(
                .observerUploadFailed(
                    DiagnosticErrorCode(capturing: error)
                )
            )
            await finishSyncActivity(
                activityID,
                outcome: .failed,
                reason: .observerUploadFailed,
                counts: SyncActivityCounts(
                    staged: 0,
                    uploaded: 0,
                    pending: syncSummary.pendingUploadCount,
                    failed: 1
                )
            )
        }
    }

    private func publishSyncSummaryIfChanged(_ summary: SyncSummary) {
        guard syncSummary != summary else {
            return
        }
        syncSummary = summary
    }

    private func publishObserverSyncCompletionIfAppropriate(
        _ outcome: LiveSyncOutcome
    ) {
        guard
            let completionState = Self.observerSyncCompletionState(
                replacing: operationState,
                report: outcome.report,
                summary: outcome.summary
            )
        else {
            return
        }
        setOperationState(completionState, origin: .automatic)
    }

    static func syncCompletionState(
        report: SyncReport,
        summary: SyncSummary
    ) -> OperationState {
        if summary.permanentFailureCount > 0 {
            let count = summary.permanentFailureCount
            let subject = "\(count) upload" + (count == 1 ? "" : "s")
            let verb = count == 1 ? "needs" : "need"
            return .failed(
                .sync,
                "\(subject) \(verb) attention. The local copies are safe."
            )
        }
        if !report.failures.isEmpty {
            let count = report.failures.count
            let subject = "\(count) upload" + (count == 1 ? "" : "s")
            return .failed(
                .sync,
                "\(subject) could not finish. The local copies are safe to retry."
            )
        }
        if summary.pendingUploadCount > 0 {
            let count = summary.pendingUploadCount
            let subject = "\(count) upload" + (count == 1 ? "" : "s")
            let verb = count == 1 ? "remains" : "remain"
            return .warning(
                .sync,
                "\(subject) \(verb) pending. The local copies are safe."
            )
        }
        return .succeeded(.sync, successMessage(for: report))
    }

    static func observerSyncCompletionState(
        replacing currentState: OperationState,
        report: SyncReport,
        summary: SyncSummary
    ) -> OperationState? {
        switch currentState {
        case .idle:
            break
        case .warning(let kind, _),
             .succeeded(let kind, _),
             .failed(let kind, _):
            guard kind == .sync else {
                return nil
            }
        case .working:
            return nil
        }
        let nextState = syncCompletionState(
            report: report,
            summary: summary
        )
        return nextState == currentState ? nil : nextState
    }

    private static func successMessage(for report: SyncReport) -> String {
        if report.uploadedDailyCount > 0 {
            return "Synced \(report.uploadedDailyCount) daily "
                + (report.uploadedDailyCount == 1 ? "record." : "records.")
        }
        if report.stagedDailyCount > 0 {
            return "Saved \(report.stagedDailyCount) daily "
                + (report.stagedDailyCount == 1
                    ? "record locally."
                    : "records locally.")
        }
        return "Everything is up to date."
    }

    static func driveDestinationChanged(
        in report: SyncReport
    ) -> Bool {
        report.failures.contains {
            $0.code == "drive_destination_changed"
        }
    }

    private func setSelectedBackfillStart(_ date: Date) {
        setSelectedBackfillStart(BackfillDateCodec.string(from: date))
    }

    private func setSelectedBackfillStart(_ value: String) {
        selectedBackfillStart = value
        UserDefaults.standard.set(
            selectedBackfillStart,
            forKey: "backfill.selectedStart"
        )
    }

    private func resolvedBackfillStart() throws -> LocalDate {
        try LocalDate(rawValue: selectedBackfillStart)
    }

    @discardableResult
    private func requireGoogleReconnect(
        for report: SyncReport,
        expectedEpoch: UInt64
    ) async -> Bool {
        guard report.failures.contains(where: {
            [
                "drive_401",
                "drive_reauthorization_required",
            ].contains($0.code)
        }) else {
            return false
        }
        return await markGoogleReconnectRequired(
            expectedEpoch: expectedEpoch
        )
    }

    @discardableResult
    private func requireGoogleReconnect(
        for error: Error,
        expectedEpoch: UInt64
    ) async -> Bool {
        let required: Bool
        if let driveError = error as? DriveAPIError {
            if case .reauthorizationRequired = driveError {
                required = true
            } else {
                required = false
            }
        } else if let authError = error as? GoogleAuthError {
            switch authError {
            case
                .identityUnavailable,
                .signedOut,
                .scopeNotGranted,
                .reauthorizationRequired:
                required = true
            case
                .configurationMissing,
                .accountChanged,
                .presenterUnavailable,
                .refreshTemporarilyUnavailable:
                required = false
            }
        } else {
            required = false
        }
        if required {
            return await markGoogleReconnectRequired(
                expectedEpoch: expectedEpoch
            )
        }
        return false
    }

    @discardableResult
    private func markGoogleReconnectRequired(
        expectedEpoch: UInt64
    ) async -> Bool {
        guard isGoogleTransitionCurrent(expectedEpoch) else {
            return false
        }
        let expectedActivation = activeDriveActivation
        if let expectedActivation {
            do {
                try await driveClient.clearActiveAccount(
                    ifMatching: expectedActivation
                )
            } catch {
                guard isGoogleTransitionCurrent(expectedEpoch) else {
                    return false
                }
                activeDriveActivation = nil
                googleConnection = .temporarilyUnavailable
                return false
            }
        }
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            activeDriveActivation == expectedActivation
        else {
            return false
        }
        activeDriveActivation = nil
        googleConnection = googleConfiguration.isConfigured
            ? .reauthorizationRequired
            : .notConfigured
        return true
    }

    @discardableResult
    private func markDriveUnavailableIfNeeded(
        expectedEpoch: UInt64
    ) async -> Bool {
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            let account = googleConnection.account
        else {
            return false
        }
        let expectedActivation = activeDriveActivation
        if let expectedActivation {
            do {
                try await driveClient.clearActiveAccount(
                    ifMatching: expectedActivation
                )
            } catch {
                guard isGoogleTransitionCurrent(expectedEpoch) else {
                    return false
                }
                activeDriveActivation = nil
                googleConnection = .temporarilyUnavailable
                return false
            }
        }
        guard
            isGoogleTransitionCurrent(expectedEpoch),
            activeDriveActivation == expectedActivation
        else {
            return false
        }
        activeDriveActivation = nil
        googleConnection = .driveUnavailable(account)
        return true
    }

    @discardableResult
    private func beginGoogleTransition() -> UInt64 {
        googleTransitionEpoch &+= 1
        return googleTransitionEpoch
    }

    private func isGoogleTransitionCurrent(_ epoch: UInt64) -> Bool {
        googleTransitionEpoch == epoch
    }

    private func settleStaleOperation(
        ifCurrent expectedState: OperationState,
        expectedEpoch: UInt64
    ) {
        guard
            operationEpoch == expectedEpoch,
            operationState == expectedState
        else {
            return
        }
        operationState = .idle
    }

    private func settleGoogleOperation(
        ifCurrent expectedState: OperationState,
        expectedEpoch: UInt64
    ) {
        guard
            operationEpoch == expectedEpoch,
            operationState == expectedState
        else {
            return
        }
        switch googleConnection {
        case .reauthorizationRequired:
            operationState = .failed(
                .googleConnection,
                Self.googleReconnectMessage
            )
        case .temporarilyUnavailable:
            operationState = .failed(
                .googleConnection,
                "Google could not be reached yet. HealthMule will retry when the app becomes active again."
            )
        case .authorized, .driveUnavailable:
            operationState = .failed(
                .googleConnection,
                "Google is authorized, but Drive folder setup still needs to finish."
            )
        case .notConfigured, .restoring, .disconnected:
            operationState = .failed(
                .googleConnection,
                "Connect Google Drive to continue."
            )
        case .connected:
            operationState = .idle
        }
    }

    private static let googleReconnectMessage =
        "Google Drive access needs approval. Reconnect in Setup; local copies are safe."

    private func loadUITestState() {
        let arguments = ProcessInfo.processInfo.arguments
        let account = GoogleAccount(
            id: "ui-test-account",
            email: "person@example.com"
        )
        selectedTab = .home
        if arguments.contains("--ui-ready")
            || arguments.contains("--ui-google-connected")
        {
            googleConnection = .connected(
                GoogleConnection(
                    account: account,
                    folderID: "ui-test-folder",
                    folderName: "Apple Health Sync"
                )
            )
        } else if arguments.contains("--ui-google-authorized") {
            googleConnection = .authorized(account)
        } else if arguments.contains("--ui-google-drive-unavailable") {
            googleConnection = .driveUnavailable(account)
        } else if arguments.contains("--ui-google-restoring") {
            googleConnection = .restoring
        } else if arguments.contains("--ui-google-unavailable") {
            googleConnection = .temporarilyUnavailable
        } else if arguments.contains("--ui-google-reconnect") {
            googleConnection = .reauthorizationRequired
        } else if arguments.contains("--ui-google-disconnected") {
            googleConnection = .disconnected
        } else {
            googleConnection = .notConfigured
        }

        isHealthKitAvailable = !arguments.contains("--ui-health-unavailable")
        if !isHealthKitAvailable {
            healthAuthorizationState = .unavailable
        } else if arguments.contains("--ui-health-checking") {
            healthAuthorizationState = .checking
        } else if arguments.contains("--ui-health-status-unavailable") {
            healthAuthorizationState = .statusUnavailable(
                previouslyRequested: arguments.contains(
                    "--ui-health-previously-requested"
                )
            )
        } else if arguments.contains("--ui-health-review") {
            healthAuthorizationState = .reviewRequired
        } else if arguments.contains("--ui-ready")
            || arguments.contains("--ui-health-request-complete")
        {
            healthAuthorizationState = .requestCompleted
        } else {
            healthAuthorizationState = .notRequested
        }

        metricStatuses = HealthMetric.allCases.enumerated().map { index, metric in
            let state: MetricReadState
            if arguments.contains("--ui-health-readable"), index < 3 {
                state = .readable(
                    lastSampleAt: Date(timeIntervalSince1970: 1_752_883_200)
                )
            } else {
                switch healthAuthorizationState {
                case .unavailable:
                    state = .unavailable
                case .checking:
                    state = .checking
                case .statusUnavailable:
                    state = .checkFailed
                case .notRequested:
                    state = .notRequested
                case .reviewRequired, .requestCompleted:
                    state = .noReadableData
                }
            }
            return MetricStatus(metric: metric, state: state)
        }
        if arguments.contains("--ui-permanent-failure") {
            syncSummary = SyncSummary(
                lastSuccessfulSyncAt: nil,
                latestExportedDate: "2026-07-23",
                pendingUploadCount: 1,
                retryableUploadCount: 0,
                permanentFailureCount: 1
            )
        } else if arguments.contains("--ui-synced") {
            syncSummary = SyncSummary(
                lastSuccessfulSyncAt: Date(
                    timeIntervalSince1970: 1_753_300_000
                ),
                latestExportedDate: "2026-07-23",
                pendingUploadCount: 0,
                retryableUploadCount: 0,
                permanentFailureCount: 0
            )
        } else {
            syncSummary = .empty
        }
        let activityTime = Date(timeIntervalSince1970: 1_753_300_000)
        let backgroundReceipt = SyncActivityReceipt(
            id: UUID(),
            startedAt: activityTime.addingTimeInterval(-120),
            finishedAt: activityTime.addingTimeInterval(-90),
            trigger: .backgroundRefresh,
            outcome: arguments.contains("--ui-activity-pending")
                ? .pending
                : arguments.contains("--ui-activity-skipped")
                    ? .skipped
                    : .succeeded,
            reason: arguments.contains("--ui-activity-skipped")
                ? .driveNotReady
                : nil,
            counts: arguments.contains("--ui-activity-pending")
                ? SyncActivityCounts(
                    staged: 1,
                    uploaded: 0,
                    pending: 1,
                    failed: 0
                )
                : .zero
        )
        if arguments.contains("--ui-activity-success") {
            syncActivitySummary = SyncActivitySummary(
                receipts: [
                    SyncActivityReceipt(
                        id: UUID(),
                        startedAt: activityTime.addingTimeInterval(-30),
                        finishedAt: activityTime,
                        trigger: .foreground,
                        outcome: .succeeded
                    ),
                    backgroundReceipt,
                ],
                schedule: BackgroundRefreshScheduleReceipt(
                    attemptedAt: activityTime,
                    result: .submitted
                )
            )
        } else if arguments.contains("--ui-activity-pending")
            || arguments.contains("--ui-activity-skipped")
        {
            syncActivitySummary = SyncActivitySummary(
                receipts: [backgroundReceipt],
                schedule: BackgroundRefreshScheduleReceipt(
                    attemptedAt: activityTime,
                    result: .existingRequestKept
                )
            )
        } else {
            syncActivitySummary = .empty
        }
        backfillRange = .thirtyDays
        customBackfillStartValue = BackfillDateCodec.string(
            from: BackfillRange.thirtyDays.startDate(customDate: .now)
        )
        enabledMetrics = Set(HealthMetric.allCases)
        if arguments.contains("--ui-operation-working") {
            setOperationState(
                .working(.sync, "Syncing"),
                origin: .automatic
            )
            if arguments.contains("--ui-sync-progress") {
                syncProgressState.begin(epoch: operationEpoch)
                syncProgressState.publish(
                    SyncProgress(
                        phase: .staging,
                        completedUnits: 12,
                        totalUnits: 30,
                        currentDate: try? LocalDate(
                            rawValue: "2026-07-12"
                        )
                    ),
                    epoch: operationEpoch
                )
            }
        } else if arguments.contains("--ui-operation-failed-automatic") {
            setOperationState(
                .failed(.sync, "Automatic sync failed."),
                origin: .automatic
            )
        } else if arguments.contains("--ui-operation-failed-user") {
            setOperationState(
                .failed(.sync, "Manual sync failed."),
                origin: .userInitiated
            )
        } else if arguments.contains("--ui-permanent-failure") {
            setOperationState(
                .failed(
                    .sync,
                    "Google Drive rejected one upload."
                ),
                origin: .automatic
            )
        } else {
            setOperationState(.idle, origin: .automatic)
        }
    }
}
