@preconcurrency import HealthKit
import Foundation
import HealthMuleCore

struct BackgroundDeliveryRegistrationResult: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case enable
        case disable
    }

    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(BackgroundDeliveryFailureCode)
    }

    let metric: HealthMetric
    let operation: Operation
    let outcome: Outcome
}

enum BackgroundDeliveryFailureCode: Equatable, Sendable {
    case unsuccessful
    case healthKit(Int)
    case errorType(String)
}

struct BackgroundDeliveryRegistrationSummary: Equatable, Sendable {
    let results: [BackgroundDeliveryRegistrationResult]

    var failedEnabledMetrics: Set<HealthMetric> {
        Set(results.compactMap { result in
            guard
                result.operation == .enable,
                case .failed = result.outcome
            else {
                return nil
            }
            return result.metric
        })
    }
}

// HealthKit's observer completion is @unchecked Sendable so the callback can
// hop off the query queue. Call it once, before any staging work.
private final class HealthObserverCompletion: @unchecked Sendable {
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func callAsFunction() {
        callback()
    }
}

// HKQuery callbacks and `HKHealthStore.stop` can race the Swift cancellation
// handler. This box holds the query and resumes the continuation exactly once.
final class HealthKitQueryResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?
    private var query: HKQuery?
    private var cancelled = false

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            query = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func shouldStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil && !cancelled
    }

    func executeIfActive(_ query: HKQuery, on healthStore: HKHealthStore) {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        self.query = query
        healthStore.execute(query)
        lock.unlock()
    }

    func stopIfNeeded(on healthStore: HKHealthStore) {
        lock.lock()
        cancelled = true
        let query = self.query
        lock.unlock()
        if let query {
            healthStore.stop(query)
        }
    }

    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    func resume(throwing error: any Error) {
        resume(with: .failure(error))
    }

    func resume(with result: Result<Value, any Error>) {
        lock.lock()
        query = nil
        if let continuation {
            self.continuation = nil
            pending = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if pending == nil {
            pending = result
        }
        lock.unlock()
    }
}

enum HealthKitClientError: LocalizedError {
    case unavailable
    case queryFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Health data is only available on a supported iPhone."
        case .queryFailed:
            "Apple Health could not complete the request."
        }
    }
}

enum HealthChangeDateMapper {
    static func reconciliationDates(
        for metric: HealthMetric,
        directlyAffectedDates: Set<String>
    ) throws -> Set<String> {
        guard metric == .sleep else {
            return directlyAffectedDates
        }

        var result = directlyAffectedDates
        for rawDate in directlyAffectedDates {
            let date = try LocalDate(rawValue: rawDate)
            result.insert(try followingDate(after: date).rawValue)
        }
        return result
    }

    private static func followingDate(after date: LocalDate) throws -> LocalDate {
        let parts = date.rawValue.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            throw SchemaValidationError.invalidLocalDate(date.rawValue)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            throw SchemaValidationError.invalidTimeZone("UTC")
        }
        calendar.timeZone = utc
        guard
            let instant = calendar.date(
                from: DateComponents(year: year, month: month, day: day)
            ),
            let following = calendar.date(
                byAdding: .day,
                value: 1,
                to: instant
            )
        else {
            throw SchemaValidationError.invalidLocalDate(date.rawValue)
        }
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: following
        )
        guard
            let followingYear = components.year,
            let followingMonth = components.month,
            let followingDay = components.day
        else {
            throw SchemaValidationError.invalidLocalDate(date.rawValue)
        }
        return try LocalDate(
            year: followingYear,
            month: followingMonth,
            day: followingDay
        )
    }
}

struct HealthAnchoredChangeBatch: Sendable {
    let metric: HealthMetric
    let affectedDates: Set<String>
    let anchor: HKQueryAnchor
    let queryStart: Date
    let sampleDates: [UUID: Set<String>]
    let deletedUUIDs: Set<UUID>
}

struct HealthAuxiliaryRecoverySummary: Equatable, Sendable {
    let resetAnchors: Bool
    let rebuiltBoundaryCount: Int
}

protocol HealthChangeTracking: Actor {
    func recoverAuxiliaryState(
        from existingRecords: [DailyHealthRecord]
    ) async throws -> HealthAuxiliaryRecoverySummary
    func startDate(for date: LocalDate) async throws -> Date
    func changedDates(
        for metric: HealthMetric,
        calendar: Calendar,
        notBefore requestedStart: Date
    ) async throws -> HealthAnchoredChangeBatch
    func commit(_ batch: HealthAnchoredChangeBatch) async throws
    func resetAnchors() async throws
}

actor HealthKitClient: HealthChangeTracking {
    private static let authorizationRequestedKey =
        "health.authorization.requested"
    private static let requestedMetricsKey =
        "health.authorization.requestedMetrics"

    typealias ObservationHandler = @MainActor @Sendable (HealthMetric) async -> Void

    let store: HKHealthStore
    private let anchorStore: HealthAnchorStore
    let dayBoundaryStore: DayBoundaryStore
    private let defaults: UserDefaults
    private var observerQueries: [HKObserverQuery] = []
    private var observationHandler: ObservationHandler?
    var vo2WindowCache: HealthKitSampleWindowCache<HKQuantitySample>?
    var sleepWindowCache: HealthKitSampleWindowCache<HKCategorySample>?

    init(
        store: HKHealthStore = HKHealthStore(),
        anchorDirectoryURL: URL? = nil,
        dayBoundaryDirectoryURL: URL? = nil,
        defaultsSuiteName: String? = nil
    ) {
        self.store = store
        anchorStore = HealthAnchorStore(directoryURL: anchorDirectoryURL)
        dayBoundaryStore = DayBoundaryStore(
            directoryURL: dayBoundaryDirectoryURL
        )
        defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
    }

    func resetDailyQueryWindows() {
        vo2WindowCache = nil
        sleepWindowCache = nil
    }

    func executeCancellableQuery<Value: Sendable>(
        _ makeQuery: (HealthKitQueryResume<Value>) -> HKQuery
    ) async throws -> Value {
        let resume = HealthKitQueryResume<Value>()
        let healthStore = store
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resume.attach(continuation)
                guard resume.shouldStart() else { return }
                let query = makeQuery(resume)
                resume.executeIfActive(query, on: healthStore)
            }
        } onCancel: {
            resume.stopIfNeeded(on: healthStore)
            resume.resume(throwing: CancellationError())
        }
    }

    nonisolated var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(
        for enabledMetrics: Set<HealthMetric>
    ) async throws -> BackgroundDeliveryRegistrationSummary {
        guard isAvailable else {
            throw HealthKitClientError.unavailable
        }
        let previouslyRequestedMetrics = requestedMetrics()
        let readTypes = HealthMetric.readTypes(for: enabledMetrics)
        if !readTypes.isEmpty {
            try await store.requestAuthorization(
                toShare: Set<HKSampleType>(),
                read: readTypes
            )
        }
        defaults.set(
            true,
            forKey: Self.authorizationRequestedKey
        )
        persistRequestedMetrics(
            previouslyRequestedMetrics.union(enabledMetrics)
        )
        return await updateBackgroundDelivery(for: enabledMetrics)
    }

    func authorizationWasRequested() -> Bool {
        defaults.bool(forKey: Self.authorizationRequestedKey)
    }

    func queryableMetrics(
        from enabledMetrics: Set<HealthMetric>
    ) -> Set<HealthMetric> {
        enabledMetrics.intersection(requestedMetrics())
    }

    func authorizationState(
        for enabledMetrics: Set<HealthMetric>
    ) async -> HealthAuthorizationState {
        guard isAvailable else {
            return .unavailable
        }
        let wasRequested = authorizationWasRequested()
        let previouslyRequestedMetrics = requestedMetrics()
        let hasUnrequestedEnabledMetrics =
            !enabledMetrics.isSubset(of: previouslyRequestedMetrics)
        let readTypes = HealthMetric.readTypes(for: enabledMetrics)
        guard !readTypes.isEmpty else {
            return wasRequested ? .requestCompleted : .notRequested
        }
        do {
            let requestStatus = try await store.statusForAuthorizationRequest(
                toShare: Set<HKSampleType>(),
                read: readTypes
            )
            switch requestStatus {
            case .shouldRequest:
                return wasRequested ? .reviewRequired : .notRequested
            case .unnecessary:
                if !wasRequested {
                    defaults.set(
                        true,
                        forKey: Self.authorizationRequestedKey
                    )
                }
                persistRequestedMetrics(
                    previouslyRequestedMetrics.union(enabledMetrics)
                )
                return .requestCompleted
            case .unknown:
                if !wasRequested {
                    return .notRequested
                }
                return hasUnrequestedEnabledMetrics
                    ? .reviewRequired
                    : .requestCompleted
            @unknown default:
                if !wasRequested {
                    return .notRequested
                }
                return hasUnrequestedEnabledMetrics
                    ? .reviewRequired
                    : .requestCompleted
            }
        } catch {
            return .statusUnavailable(previouslyRequested: wasRequested)
        }
    }

    func metricStatuses(
        for authorizationState: HealthAuthorizationState,
        enabledMetrics: Set<HealthMetric>
    ) async -> [MetricStatus] {
        var result: [MetricStatus] = []
        let requestedMetrics = requestedMetrics()
        for metric in HealthMetric.allCases {
            guard enabledMetrics.contains(metric) else {
                result.append(
                    MetricStatus(metric: metric, state: .notIncluded)
                )
                continue
            }
            guard requestedMetrics.contains(metric) else {
                result.append(
                    MetricStatus(metric: metric, state: .notRequested)
                )
                continue
            }
            guard authorizationState.allowsQueries else {
                let state: MetricReadState
                switch authorizationState {
                case .unavailable:
                    state = .unavailable
                case .checking:
                    state = .checking
                case .statusUnavailable:
                    state = .checkFailed
                case .notRequested:
                    state = .notRequested
                case .reviewRequired, .requestCompleted:
                    state = .checking
                }
                result.append(MetricStatus(metric: metric, state: state))
                continue
            }
            guard isAvailable else {
                result.append(
                    MetricStatus(metric: metric, state: .unavailable)
                )
                continue
            }
            do {
                if let date = try await latestReadableSampleDate(for: metric) {
                    result.append(
                        MetricStatus(
                            metric: metric,
                            state: .readable(lastSampleAt: date)
                        )
                    )
                } else {
                    result.append(
                        MetricStatus(metric: metric, state: .noReadableData)
                    )
                }
            } catch {
                result.append(
                    MetricStatus(metric: metric, state: .checkFailed)
                )
            }
        }
        return result
    }

    func registerObservers(
        for enabledMetrics: Set<HealthMetric>,
        handler: @escaping ObservationHandler
    ) {
        observationHandler = handler
        for query in observerQueries {
            store.stop(query)
        }
        observerQueries.removeAll()

        let observableMetrics = queryableMetrics(from: enabledMetrics)
        for metric in HealthMetric.allCases where observableMetrics.contains(metric) {
            guard let sampleType = metric.sampleType else { continue }
            let query = HKObserverQuery(
                sampleType: sampleType,
                predicate: nil
            ) { [weak self] _, completion, error in
                let completion = HealthObserverCompletion(completion)
                completion()
                guard error == nil, let self else {
                    return
                }
                Task {
                    await self.deliverObservation(metric)
                }
            }
            observerQueries.append(query)
            store.execute(query)
        }
    }

    private func deliverObservation(_ metric: HealthMetric) async {
        await observationHandler?(metric)
    }

    func changedDates(
        for metric: HealthMetric,
        calendar: Calendar,
        notBefore requestedStart: Date
    ) async throws -> HealthAnchoredChangeBatch {
        guard let sampleType = metric.sampleType else {
            throw HealthKitClientError.queryFailed
        }
        var previousAnchor = anchorStore.anchor(for: metric)
        var queryStart = anchorStore.queryStart(for: metric)
        if previousAnchor != nil {
            if let storedStart = queryStart {
                if requestedStart < storedStart {
                    try anchorStore.reset(metric: metric)
                    previousAnchor = nil
                    queryStart = nil
                }
            } else {
                try anchorStore.reset(metric: metric)
                previousAnchor = nil
            }
        }
        let effectiveStart = previousAnchor == nil
            ? min(queryStart ?? requestedStart, requestedStart)
            : queryStart ?? requestedStart
        let predicate = HKQuery.predicateForSamples(
            withStart: effectiveStart,
            end: nil,
            options: []
        )
        let result = try await anchoredQuery(anchor: previousAnchor) { cursor, limit in
            try await self.anchoredPage(
                sampleType: sampleType,
                predicate: predicate,
                anchor: cursor,
                limit: limit
            )
        }
        try Task.checkCancellation()

        var dates: Set<String> = []
        var sampleDates: [UUID: Set<String>] = [:]
        for sample in result.samples {
            try Task.checkCancellation()
            let directlyAffectedDates = try dayBoundaryStore.dateKeys(
                overlappingStart: sample.startDate,
                end: sample.endDate,
                fallbackCalendar: calendar
            )
            sampleDates[sample.uuid] = directlyAffectedDates
            dates.formUnion(
                try HealthChangeDateMapper.reconciliationDates(
                    for: metric,
                    directlyAffectedDates: directlyAffectedDates
                )
            )
        }
        let deletedUUIDs = Set(result.deletedObjects.map(\.uuid))
        for uuid in deletedUUIDs {
            try Task.checkCancellation()
            dates.formUnion(
                try HealthChangeDateMapper.reconciliationDates(
                    for: metric,
                    directlyAffectedDates: try anchorStore.dates(
                        forDeletedUUID: uuid
                    )
                )
            )
        }

        return HealthAnchoredChangeBatch(
            metric: metric,
            affectedDates: dates,
            anchor: result.anchor,
            queryStart: effectiveStart,
            sampleDates: sampleDates,
            deletedUUIDs: deletedUUIDs
        )
    }

    func recoverAuxiliaryState(
        from existingRecords: [DailyHealthRecord]
    ) async throws -> HealthAuxiliaryRecoverySummary {
        var resetAnchors = false
        do {
            _ = try anchorStore.inspectSampleIndex()
        } catch is HealthAnchorStoreError {
            try Task.checkCancellation()
            try anchorStore.reset()
            resetAnchors = true
        }

        var rebuiltBoundaryCount = 0
        do {
            _ = try dayBoundaryStore.inspectBoundaries()
        } catch is DayBoundaryStoreError {
            try Task.checkCancellation()
            rebuiltBoundaryCount = try dayBoundaryStore.rebuild(
                from: existingRecords
            )
        }
        try Task.checkCancellation()
        return HealthAuxiliaryRecoverySummary(
            resetAnchors: resetAnchors,
            rebuiltBoundaryCount: rebuiltBoundaryCount
        )
    }

    func commit(_ batch: HealthAnchoredChangeBatch) async throws {
        try anchorStore.commit(
            metric: batch.metric,
            anchor: batch.anchor,
            queryStart: batch.queryStart,
            sampleDates: batch.sampleDates,
            deletedUUIDs: batch.deletedUUIDs
        )
    }

    func resetAnchors() async throws {
        try anchorStore.reset()
    }

    func startDate(for date: LocalDate) async throws -> Date {
        try dayBoundaryStore.boundary(
            for: date,
            currentTimeZone: .current
        ).start
    }

    private func latestReadableSampleDate(
        for metric: HealthMetric
    ) async throws -> Date? {
        guard let sampleType = metric.sampleType else { return nil }
        return try await executeCancellableQuery { resume in
            let sort = NSSortDescriptor(
                key: HKSampleSortIdentifierEndDate,
                ascending: false
            )
            return HKSampleQuery(
                sampleType: sampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    resume.resume(throwing: error)
                } else {
                    resume.resume(returning: samples?.first?.endDate)
                }
            }
        }
    }

    func updateBackgroundDelivery(
        for enabledMetrics: Set<HealthMetric>
    ) async -> BackgroundDeliveryRegistrationSummary {
        let observableMetrics = queryableMetrics(from: enabledMetrics)
        var results: [BackgroundDeliveryRegistrationResult] = []
        for metric in HealthMetric.allCases {
            guard let sampleType = metric.sampleType else { continue }
            let operation: BackgroundDeliveryRegistrationResult.Operation =
                observableMetrics.contains(metric) ? .enable : .disable
            let outcome = await withCheckedContinuation { continuation in
                let callback: @Sendable (Bool, Error?) -> Void = {
                    success, error in
                    continuation.resume(
                        returning: Self.backgroundDeliveryOutcome(
                            success: success,
                            error: error
                        )
                    )
                }
                if operation == .enable {
                    store.enableBackgroundDelivery(
                        for: sampleType,
                        frequency: .immediate
                    ) { success, error in callback(success, error) }
                } else {
                    store.disableBackgroundDelivery(
                        for: sampleType
                    ) { success, error in callback(success, error) }
                }
            }
            results.append(
                BackgroundDeliveryRegistrationResult(
                    metric: metric,
                    operation: operation,
                    outcome: outcome
                )
            )
        }
        return BackgroundDeliveryRegistrationSummary(results: results)
    }

    nonisolated static func backgroundDeliveryOutcome(
        success: Bool,
        error: Error?
    ) -> BackgroundDeliveryRegistrationResult.Outcome {
        if let error {
            let nsError = error as NSError
            if nsError.domain == HKErrorDomain {
                return .failed(.healthKit(nsError.code))
            }
            return .failed(
                .errorType(String(reflecting: type(of: error)))
            )
        }
        return success ? .succeeded : .failed(.unsuccessful)
    }

    private func requestedMetrics() -> Set<HealthMetric> {
        if let rawValues = defaults.stringArray(
            forKey: Self.requestedMetricsKey
        ) {
            return Set(rawValues.compactMap(HealthMetric.init(rawValue:)))
        }
        if authorizationWasRequested() {
            return Set(HealthMetric.allCases)
        }
        return []
    }

    private func persistRequestedMetrics(
        _ metrics: Set<HealthMetric>
    ) {
        defaults.set(
            metrics.map(\.rawValue).sorted(),
            forKey: Self.requestedMetricsKey
        )
    }

    func anchoredQuery(
        anchor: HKQueryAnchor?,
        fetchPage: (HKQueryAnchor?, Int) async throws -> (
            samples: [HKSample],
            deletedObjects: [HKDeletedObject],
            anchor: HKQueryAnchor
        )
    ) async throws -> (
        samples: [HKSample],
        deletedObjects: [HKDeletedObject],
        anchor: HKQueryAnchor
    ) {
        let pageLimit = 500
        var cursor = anchor
        var allSamples: [HKSample] = []
        var allDeletedObjects: [HKDeletedObject] = []

        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(cursor, pageLimit)
            try Task.checkCancellation()
            allSamples.append(contentsOf: page.samples)
            allDeletedObjects.append(contentsOf: page.deletedObjects)
            cursor = page.anchor
            if page.samples.count + page.deletedObjects.count < pageLimit {
                break
            }
        }
        guard let cursor else {
            throw HealthKitClientError.queryFailed
        }
        return (allSamples, allDeletedObjects, cursor)
    }

    private func anchoredPage(
        sampleType: HKSampleType,
        predicate: NSPredicate,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> (
        samples: [HKSample],
        deletedObjects: [HKDeletedObject],
        anchor: HKQueryAnchor
    ) {
        try await executeCancellableQuery { resume in
            HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                guard let newAnchor else {
                    resume.resume(throwing: HealthKitClientError.queryFailed)
                    return
                }
                resume.resume(
                    returning: (
                        samples ?? [],
                        deletedObjects ?? [],
                        newAnchor
                    )
                )
            }
        }
    }

}
