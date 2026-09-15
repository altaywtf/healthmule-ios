import Foundation

struct DriveUploadResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}

protocol DriveUploadTransport: Sendable {
    func transition(toDestinationScopeID destinationScopeID: String?) async throws

    func upload(
        request: URLRequest,
        body: Data,
        operationID: String,
        destinationScopeID: String
    ) async throws -> DriveUploadResponse
}

actor BackgroundDriveUploadTransport: DriveUploadTransport {
    private enum ResponseObservation: @unchecked Sendable {
        case completion(
            Result<DriveUploadResponse, any Error>
        )
        case observationTimedOut
    }

    private final class ResultGate<Value: Sendable>:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<Value, any Error>?
        private var result: Result<Value, any Error>?

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Value, any Error>?
                lock.lock()
                result = self.result
                if result == nil {
                    self.continuation = continuation
                }
                lock.unlock()
                if let result {
                    continuation.resume(with: result)
                }
            }
        }

        func resolve(_ result: Result<Value, any Error>) {
            let continuation: CheckedContinuation<Value, any Error>?
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func cancel() {
            resolve(.failure(CancellationError()))
        }
    }

    private struct OperationKey: Hashable, Sendable {
        let destinationScopeID: String
        let operationID: String
    }

    private struct OperationReservation {
        let id: UUID
        let generation: UInt64
        let task: Task<DriveUploadResponse, Error>
        var callerCount: Int
    }

    nonisolated static let sessionIdentifier =
        "dev.uinaf.healthmule.drive-upload"
    nonisolated static let shared = BackgroundDriveUploadTransport()
    nonisolated static let defaultResponseWaitTimeout: Duration = .seconds(15)
    nonisolated static let defaultTransitionDrainTimeout: Duration =
        .seconds(15)

    private let bodyStore: BackgroundDriveUploadBodyStore
    private let sessionDelegate: BackgroundDriveUploadSessionDelegate
    private let session: URLSession
    private let responseWaitTimeout: Duration
    private let transitionDrainTimeout: Duration
    private var destinationScopeGeneration: UInt64 = 0
    private var preparedDestinationScopeID: String?
    private var operationReservations:
        [OperationKey: OperationReservation] = [:]
    private var operationTail: Task<Void, Never>?

    init(
        bodyStore: BackgroundDriveUploadBodyStore = .live(),
        configuration: URLSessionConfiguration? = nil,
        responseWaitTimeout: Duration = defaultResponseWaitTimeout,
        transitionDrainTimeout: Duration = defaultTransitionDrainTimeout
    ) {
        self.bodyStore = bodyStore
        self.responseWaitTimeout = responseWaitTimeout
        self.transitionDrainTimeout = transitionDrainTimeout
        let sessionDelegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: bodyStore
        )
        self.sessionDelegate = sessionDelegate
        self.session = URLSession(
            configuration: configuration ?? Self.makeConfiguration(),
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    nonisolated static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    func transition(
        toDestinationScopeID destinationScopeID: String?
    ) async throws {
        destinationScopeGeneration &+= 1
        let expectedGeneration = destinationScopeGeneration
        preparedDestinationScopeID = nil
        invalidateOperationReservations()

        let currentTasks = await session.allTasks
        try ensureCurrentTransition(expectedGeneration)
        let staleTasks = currentTasks.filter {
            guard let descriptor = BackgroundDriveUploadTaskDescriptor(
                encoded: $0.taskDescription
            ) else {
                return true
            }
            return descriptor.destinationScopeID != destinationScopeID
        }
        for task in staleTasks {
            switch try await observeResponse(
                for: task,
                timeout: transitionDrainTimeout
            ) {
            case .completion:
                // The delegate only publishes a completion after URLSession
                // has definitively terminated the task. An obsolete upload's
                // HTTP or transport failure is reconciled by the durable queue
                // and cannot block the new destination.
                break
            case .observationTimedOut:
                throw URLError(.timedOut)
            }
            try ensureCurrentTransition(expectedGeneration)
        }

        let remainingTasks = await session.allTasks
        try ensureCurrentTransition(expectedGeneration)
        guard remainingTasks.allSatisfy({
            guard
                let descriptor = BackgroundDriveUploadTaskDescriptor(
                    encoded: $0.taskDescription
                ),
                let destinationScopeID
            else {
                return false
            }
            return descriptor.destinationScopeID == destinationScopeID
        }) else {
            throw URLError(.cannotCloseFile)
        }
        preparedDestinationScopeID = destinationScopeID
        pruneBodies(for: remainingTasks)
    }

    func upload(
        request: URLRequest,
        body: Data,
        operationID: String,
        destinationScopeID: String
    ) async throws -> DriveUploadResponse {
        try Task.checkCancellation()
        guard preparedDestinationScopeID == destinationScopeID else {
            throw URLError(.cancelled)
        }
        let expectedScopeGeneration = destinationScopeGeneration
        let key = OperationKey(
            destinationScopeID: destinationScopeID,
            operationID: operationID
        )
        let reservation: OperationReservation
        if
            var existing = operationReservations[key],
            existing.generation == expectedScopeGeneration
        {
            existing.callerCount += 1
            operationReservations[key] = existing
            reservation = existing
        } else {
            let reservationID = UUID()
            let predecessor = operationTail
            let operationTask = Task<DriveUploadResponse, Error> {
                if let predecessor {
                    await predecessor.value
                }
                try Task.checkCancellation()
                return try await self.performUpload(
                    request: request,
                    body: body,
                    operationID: operationID,
                    destinationScopeID: destinationScopeID,
                    expectedScopeGeneration: expectedScopeGeneration
                )
            }
            reservation = OperationReservation(
                id: reservationID,
                generation: expectedScopeGeneration,
                task: operationTask,
                callerCount: 1
            )
            operationReservations[key] = reservation
            operationTail = Task<Void, Never> {
                _ = await operationTask.result
            }
        }

        defer {
            releaseOperationReservation(
                key,
                reservationID: reservation.id
            )
        }
        let resultGate = ResultGate<DriveUploadResponse>()
        Task {
            resultGate.resolve(await reservation.task.result)
        }
        return try await withTaskCancellationHandler {
            do {
                let response = try await resultGate.wait()
                try Task.checkCancellation()
                return response
            } catch is CancellationError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw URLError(.cancelled)
            }
        } onCancel: {
            resultGate.cancel()
        }
    }

    private func performUpload(
        request: URLRequest,
        body: Data,
        operationID: String,
        destinationScopeID: String,
        expectedScopeGeneration: UInt64
    ) async throws -> DriveUploadResponse {
        try ensurePreparedDestination(
            destinationScopeID,
            generation: expectedScopeGeneration
        )
        let currentTasks = await session.allTasks
        try ensurePreparedDestination(
            destinationScopeID,
            generation: expectedScopeGeneration
        )
        guard currentTasks.allSatisfy({
            BackgroundDriveUploadTaskDescriptor(
                encoded: $0.taskDescription
            )?.destinationScopeID == destinationScopeID
        }) else {
            throw URLError(.cancelled)
        }
        pruneBodies(for: currentTasks)

        if let matchingTask = currentTasks.first(where: {
            let descriptor = BackgroundDriveUploadTaskDescriptor(
                encoded: $0.taskDescription
            )
            return descriptor?.destinationScopeID == destinationScopeID
                && descriptor?.operationID == operationID
        }) {
            let response = try await boundedResponse(
                for: matchingTask,
                timeout: responseWaitTimeout
            )
            try ensurePreparedDestination(
                destinationScopeID,
                generation: expectedScopeGeneration
            )
            return response
        }

        for task in currentTasks.sorted(by: {
            $0.taskIdentifier < $1.taskIdentifier
        }) {
            do {
                _ = try await boundedResponse(
                    for: task,
                    timeout: responseWaitTimeout
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw error
            } catch {
                // A completed older operation is reconciled by the durable
                // core queue. It must not prevent the current operation.
            }
            try ensurePreparedDestination(
                destinationScopeID,
                generation: expectedScopeGeneration
            )
        }

        try Task.checkCancellation()
        try ensurePreparedDestination(
            destinationScopeID,
            generation: expectedScopeGeneration
        )
        let bodyFileURL: URL
        do {
            bodyFileURL = try bodyStore.stage(body)
        } catch {
            throw URLError(.cannotCreateFile)
        }

        var uploadRequest = request
        uploadRequest.httpBody = nil
        let task = session.uploadTask(
            with: uploadRequest,
            fromFile: bodyFileURL
        )
        task.taskDescription = BackgroundDriveUploadTaskDescriptor(
            destinationScopeID: destinationScopeID,
            operationID: operationID,
            bodyFileName: bodyFileURL.lastPathComponent
        ).encoded
        task.resume()
        let response = try await boundedResponse(
            for: task,
            timeout: responseWaitTimeout
        )
        try ensurePreparedDestination(
            destinationScopeID,
            generation: expectedScopeGeneration
        )
        return response
    }

    func handleDeliveredBackgroundEvents() async -> Bool {
        do {
            try await sessionDelegate.waitForFinishedEvents()
            let currentTasks = await session.allTasks
            pruneBodies(for: currentTasks)
            return true
        } catch {
            return false
        }
    }

    private func boundedResponse(
        for task: URLSessionTask,
        timeout: Duration
    ) async throws -> DriveUploadResponse {
        switch try await observeResponse(for: task, timeout: timeout) {
        case let .completion(result):
            return try result.get()
        case .observationTimedOut:
            throw URLError(.timedOut)
        }
    }

    private func observeResponse(
        for task: URLSessionTask,
        timeout: Duration
    ) async throws -> ResponseObservation {
        let sessionDelegate = sessionDelegate
        return try await withThrowingTaskGroup(
            of: ResponseObservation.self
        ) { group in
            group.addTask {
                do {
                    return .completion(
                        .success(
                            try await sessionDelegate.response(for: task)
                        )
                    )
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    return .completion(.failure(error))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .observationTimedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return response
        }
    }

    private func ensureCurrentTransition(_ expectedGeneration: UInt64) throws {
        guard destinationScopeGeneration == expectedGeneration else {
            throw CancellationError()
        }
    }

    private func ensurePreparedDestination(
        _ destinationScopeID: String,
        generation: UInt64
    ) throws {
        guard
            destinationScopeGeneration == generation,
            preparedDestinationScopeID == destinationScopeID
        else {
            throw URLError(.cancelled)
        }
    }

    private func releaseOperationReservation(
        _ key: OperationKey,
        reservationID: UUID
    ) {
        guard
            var reservation = operationReservations[key],
            reservation.id == reservationID
        else {
            return
        }
        reservation.callerCount -= 1
        if reservation.callerCount == 0 {
            operationReservations.removeValue(forKey: key)
            reservation.task.cancel()
        } else {
            operationReservations[key] = reservation
        }
    }

    private func invalidateOperationReservations() {
        let tasks = operationReservations.values.map(\.task)
        operationReservations.removeAll()
        operationTail = nil
        tasks.forEach { $0.cancel() }
    }

#if DEBUG
    func reservedCallerCount(
        operationID: String,
        destinationScopeID: String
    ) -> Int {
        operationReservations[
            OperationKey(
                destinationScopeID: destinationScopeID,
                operationID: operationID
            )
        ]?.callerCount ?? 0
    }

    func responseWaiterCountForTesting() -> Int {
        sessionDelegate.totalResponseWaiterCountForTesting()
    }
#endif

    private func pruneBodies(for tasks: [URLSessionTask]) {
        let activeBodyFileNames = Set(
            tasks.compactMap {
                BackgroundDriveUploadTaskDescriptor(
                    encoded: $0.taskDescription
                )?.bodyFileName
            }
        )
        bodyStore.prune(keeping: activeBodyFileNames)
    }
}

struct BackgroundDriveUploadTaskDescriptor: Equatable, Sendable {
    private static let version = "v2"

    let destinationScopeID: String
    let operationID: String
    let bodyFileName: String

    init(
        destinationScopeID: String,
        operationID: String,
        bodyFileName: String
    ) {
        self.destinationScopeID = destinationScopeID
        self.operationID = operationID
        self.bodyFileName = bodyFileName
    }

    init?(encoded: String?) {
        guard let encoded else { return nil }
        let components = encoded.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard
            components.count == 4,
            components[0] == Self.version,
            components[1].count == 64,
            components[1].allSatisfy({ $0.isHexDigit }),
            components[2].count == 64,
            components[2].allSatisfy({ $0.isHexDigit }),
            Self.isValidBodyFileName(String(components[3]))
        else {
            return nil
        }
        destinationScopeID = String(components[1])
        operationID = String(components[2])
        bodyFileName = String(components[3])
    }

    var encoded: String {
        "\(Self.version)|\(destinationScopeID)|\(operationID)|\(bodyFileName)"
    }

    static func isValidBodyFileName(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(".upload") else { return false }
        let uuid = String(fileName.dropLast(".upload".count))
        return UUID(uuidString: uuid) != nil
    }
}

struct BackgroundDriveUploadBodyStore: Sendable {
    let directoryURL: URL

    static func live() -> BackgroundDriveUploadBodyStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return BackgroundDriveUploadBodyStore(
            directoryURL: applicationSupport
                .appendingPathComponent("HealthMule", isDirectory: true)
                .appendingPathComponent("DriveUploads", isDirectory: true)
        )
    }

    func stage(_ body: Data) throws -> URL {
        try prepareDirectory()
        let fileURL = directoryURL
            .appendingPathComponent(
                "\(UUID().uuidString).upload",
                isDirectory: false
            )
        try body.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(resourceValues)
        return fileURL
    }

    func remove(fileName: String) {
        guard BackgroundDriveUploadTaskDescriptor.isValidBodyFileName(fileName)
        else {
            return
        }
        try? FileManager.default.removeItem(
            at: directoryURL.appendingPathComponent(fileName)
        )
    }

    func prune(keeping fileNames: Set<String>) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        for fileURL in contents
        where
            !fileNames.contains(fileURL.lastPathComponent)
            && fileURL.pathExtension == "upload"
        {
            remove(fileName: fileURL.lastPathComponent)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryURL = directoryURL
        try directoryURL.setResourceValues(resourceValues)
    }
}

final class BackgroundDriveUploadSessionDelegate:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    typealias CacheExpiryScheduler =
        @Sendable (
            Duration,
            @escaping @Sendable () -> Void
        ) -> Void

    private final class ResultGate<Value: Sendable>:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<Value, any Error>?
        private var result: Result<Value, any Error>?

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return result != nil
        }

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Value, any Error>?
                lock.lock()
                result = self.result
                if result == nil {
                    self.continuation = continuation
                }
                lock.unlock()
                if let result {
                    continuation.resume(with: result)
                }
            }
        }

        @discardableResult
        func resolve(_ result: Result<Value, any Error>) -> Bool {
            let continuation: CheckedContinuation<Value, any Error>?
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }

        @discardableResult
        func cancel() -> Bool {
            resolve(.failure(CancellationError()))
        }
    }

    private struct CompletedResponse {
        let generation: UInt64
        let result: Result<DriveUploadResponse, any Error>
    }

    private struct CompletedResponseKey: Equatable {
        let taskIdentifier: Int
        let generation: UInt64
    }

    private struct State {
        var responseData: [Int: Data] = [:]
        var responseWaiters:
            [Int: [UUID: ResultGate<DriveUploadResponse>]] = [:]
        var completedResponses: [Int: CompletedResponse] = [:]
        var completedResponseOrder: [CompletedResponseKey] = []
        var nextCompletionGeneration: UInt64 = 0
        var eventWaiters: [UUID: ResultGate<Void>] = [:]
        var unclaimedFinishedEventCount = 0
    }

    private let bodyStore: BackgroundDriveUploadBodyStore
    private let completedResponseLimit: Int
    private let completedResponseGracePeriod: Duration
    private let cacheExpiryScheduler: CacheExpiryScheduler
    private let lock = NSLock()
    private var state = State()

    init(
        bodyStore: BackgroundDriveUploadBodyStore,
        completedResponseLimit: Int = 32,
        completedResponseGracePeriod: Duration = .seconds(60),
        cacheExpiryScheduler:
            @escaping CacheExpiryScheduler = { duration, action in
                Task {
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    action()
                }
            }
    ) {
        self.bodyStore = bodyStore
        self.completedResponseLimit = max(1, completedResponseLimit)
        self.completedResponseGracePeriod =
            completedResponseGracePeriod
        self.cacheExpiryScheduler = cacheExpiryScheduler
    }

    func response(for task: URLSessionTask) async throws
        -> DriveUploadResponse
    {
        try await response(forTaskIdentifier: task.taskIdentifier)
    }

    private func response(
        forTaskIdentifier taskIdentifier: Int
    ) async throws -> DriveUploadResponse {
        let waiterID = UUID()
        let resultGate = ResultGate<DriveUploadResponse>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            registerResponseWaiter(
                resultGate,
                taskIdentifier: taskIdentifier,
                waiterID: waiterID
            )
            let response = try await resultGate.wait()
            try Task.checkCancellation()
            return response
        } onCancel: {
            self.cancelResponseWaiter(
                taskIdentifier: taskIdentifier,
                waiterID: waiterID,
                resultGate: resultGate
            )
        }
    }

    func waitForFinishedEvents() async throws {
        try await waitForFinishedEvents(beforeRegistration: nil)
    }

    private func waitForFinishedEvents(
        beforeRegistration: (@Sendable () -> Void)?
    ) async throws {
        let waiterID = UUID()
        let resultGate = ResultGate<Void>()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            beforeRegistration?()
            registerEventWaiter(resultGate, waiterID: waiterID)
            try await resultGate.wait()
        } onCancel: {
            self.cancelEventWaiter(
                waiterID: waiterID,
                resultGate: resultGate
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        state.responseData[dataTask.taskIdentifier, default: Data()]
            .append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let responseData: Data
        let result: Result<DriveUploadResponse, any Error>

        lock.lock()
        responseData = state.responseData.removeValue(
            forKey: task.taskIdentifier
        ) ?? Data()
        if let error {
            result = .failure(error)
        } else if let response = task.response {
            result = .success(
                DriveUploadResponse(data: responseData, response: response)
            )
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        lock.unlock()

        completeResponse(
            taskIdentifier: task.taskIdentifier,
            result: result
        )
        if
            let fileName = BackgroundDriveUploadTaskDescriptor(
                encoded: task.taskDescription
            )?.bodyFileName
        {
            bodyStore.remove(fileName: fileName)
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        completeFinishedEvents()
    }

    private func registerResponseWaiter(
        _ resultGate: ResultGate<DriveUploadResponse>,
        taskIdentifier: Int,
        waiterID: UUID
    ) {
        let result: Result<DriveUploadResponse, any Error>?
        lock.lock()
        result = state.completedResponses[taskIdentifier]?.result
        if result == nil, !resultGate.isResolved {
            state.responseWaiters[taskIdentifier, default: [:]][waiterID] =
                resultGate
        }
        lock.unlock()

        if let result {
            resultGate.resolve(result)
        }
    }

    private func cancelResponseWaiter(
        taskIdentifier: Int,
        waiterID: UUID,
        resultGate: ResultGate<DriveUploadResponse>
    ) {
        lock.lock()
        state.responseWaiters[taskIdentifier]?
            .removeValue(forKey: waiterID)
        if state.responseWaiters[taskIdentifier]?.isEmpty == true {
            state.responseWaiters.removeValue(forKey: taskIdentifier)
        }
        lock.unlock()
        resultGate.cancel()
    }

    private func completeResponse(
        taskIdentifier: Int,
        result: Result<DriveUploadResponse, any Error>
    ) {
        let waiters: [ResultGate<DriveUploadResponse>]
        let generation: UInt64

        lock.lock()
        let registeredWaiters = state.responseWaiters.removeValue(
            forKey: taskIdentifier
        ) ?? [:]
        waiters = Array(registeredWaiters.values)
        state.nextCompletionGeneration &+= 1
        generation = state.nextCompletionGeneration
        state.completedResponseOrder.removeAll {
            $0.taskIdentifier == taskIdentifier
        }
        state.completedResponses[taskIdentifier] = CompletedResponse(
            generation: generation,
            result: result
        )
        state.completedResponseOrder.append(
            CompletedResponseKey(
                taskIdentifier: taskIdentifier,
                generation: generation
            )
        )
        while
            state.completedResponses.count > completedResponseLimit,
            !state.completedResponseOrder.isEmpty
        {
            let oldest = state.completedResponseOrder.removeFirst()
            if
                state.completedResponses[oldest.taskIdentifier]?
                    .generation == oldest.generation
            {
                state.completedResponses.removeValue(
                    forKey: oldest.taskIdentifier
                )
            }
        }
        lock.unlock()

        cacheExpiryScheduler(completedResponseGracePeriod) {
            [weak self] in
            self?.expireCompletedResponse(
                taskIdentifier: taskIdentifier,
                generation: generation
            )
        }
        for waiter in waiters {
            waiter.resolve(result)
        }
    }

    private func expireCompletedResponse(
        taskIdentifier: Int,
        generation: UInt64
    ) {
        lock.lock()
        if
            state.completedResponses[taskIdentifier]?.generation
                == generation
        {
            state.completedResponses.removeValue(
                forKey: taskIdentifier
            )
            state.completedResponseOrder.removeAll {
                $0.taskIdentifier == taskIdentifier
                    && $0.generation == generation
            }
        }
        lock.unlock()
    }

#if DEBUG
    func waitForFinishedEventsForTesting(
        beforeRegistration: @escaping @Sendable () -> Void
    ) async throws {
        try await waitForFinishedEvents(
            beforeRegistration: beforeRegistration
        )
    }

    func completeFinishedEventsForTesting() {
        completeFinishedEvents()
    }

    func unclaimedFinishedEventCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.unclaimedFinishedEventCount
    }

    func eventWaiterCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.eventWaiters.count
    }

    func responseForTesting(
        taskIdentifier: Int
    ) async throws -> DriveUploadResponse {
        try await response(forTaskIdentifier: taskIdentifier)
    }

    func completeResponseForTesting(
        taskIdentifier: Int,
        result: Result<DriveUploadResponse, any Error>
    ) {
        completeResponse(taskIdentifier: taskIdentifier, result: result)
    }

    func responseWaiterCountForTesting(taskIdentifier: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.responseWaiters[taskIdentifier]?.count ?? 0
    }

    func totalResponseWaiterCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.responseWaiters.values.reduce(0) {
            $0 + $1.count
        }
    }

    func completedResponseCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.completedResponses.count
    }

    func hasCompletedResponseForTesting(taskIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.completedResponses[taskIdentifier] != nil
    }
#endif

    private func registerEventWaiter(
        _ resultGate: ResultGate<Void>,
        waiterID: UUID
    ) {
        lock.lock()
        if state.unclaimedFinishedEventCount > 0 {
            if resultGate.resolve(.success(())) {
                state.unclaimedFinishedEventCount -= 1
            }
        } else if !resultGate.isResolved {
            state.eventWaiters[waiterID] = resultGate
        }
        lock.unlock()
    }

    private func cancelEventWaiter(
        waiterID: UUID,
        resultGate: ResultGate<Void>
    ) {
        lock.lock()
        state.eventWaiters.removeValue(forKey: waiterID)
        resultGate.cancel()
        lock.unlock()
    }

    private func completeFinishedEvents() {
        lock.lock()
        let waiters = Array(state.eventWaiters)
        var acceptedFinishedEvent = false
        for (waiterID, waiter) in waiters {
            if waiter.resolve(.success(())) {
                acceptedFinishedEvent = true
                state.eventWaiters.removeValue(forKey: waiterID)
                break
            }
            state.eventWaiters.removeValue(forKey: waiterID)
        }
        if !acceptedFinishedEvent {
            state.unclaimedFinishedEventCount += 1
        }
        lock.unlock()
    }
}
