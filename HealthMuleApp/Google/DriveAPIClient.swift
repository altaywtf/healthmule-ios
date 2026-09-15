import CryptoKit
import Foundation
import OSLog

struct DriveRemoteItem: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let webViewLink: String?
    let appProperties: [String: String]?
    let mimeType: String?
    let trashed: Bool?
    let parents: [String]?
}

struct DriveFolderConnection: Equatable, Sendable {
    let rootID: String
    let dailyID: String
    let name: String

    var url: URL? {
        URL(string: "https://drive.google.com/drive/folders/\(rootID)")
    }
}

struct DriveAccountActivation: Equatable, Sendable {
    let accountID: String
    fileprivate let generation: UInt64
}

private struct DriveFolderIdentity: Equatable, Sendable {
    let rootID: String
    let dailyID: String

    init(_ folders: DriveFolderConnection) {
        rootID = folders.rootID
        dailyID = folders.dailyID
    }
}

enum DriveAPIError: LocalizedError, Sendable {
    case invalidResponse
    case reauthorizationRequired
    case authenticationUnavailable
    case accountNotReady
    case destinationChanged
    case remote(status: Int, reason: String?, retryable: Bool)
    case transport(code: URLError.Code)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Drive returned an invalid response."
        case .reauthorizationRequired:
            "Google Drive access needs approval. Reconnect your account."
        case .authenticationUnavailable:
            "Google authorization could not be refreshed yet. The upload will be retried."
        case .accountNotReady:
            "Google Drive is not ready for the active account. The upload will be retried."
        case .destinationChanged:
            "The managed Google Drive folders changed. Sync state will be refreshed before uploading."
        case .remote(let status, let reason, _):
            "Google Drive request failed (\(status)\(reason.map { ": \($0)" } ?? ""))."
        case .transport:
            "Google Drive could not be reached. The upload will be retried."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .remote(_, _, let retryable):
            retryable
        case
            .accountNotReady,
            .authenticationUnavailable,
            .destinationChanged,
            .transport:
            true
        case .invalidResponse, .reauthorizationRequired:
            false
        }
    }
}

actor DriveAPIClient {
    typealias TokenProvider =
        @MainActor @Sendable (String) async throws -> String

    private struct UpsertQueueKey: Hashable, Sendable {
        let accountID: String
        let destinationScopeID: String
        let cacheKey: String
    }

    private struct UpsertQueueState {
        let tail: Task<Void, Never>
        var reservationIDs: Set<UUID>
    }

    private struct FolderReservation {
        let id: UUID
        let task: Task<DriveFolderConnection, Error>
        var callerCount: Int
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

    private static let filesBaseURL = URL(
        string: "https://www.googleapis.com/drive/v3/files"
    )!
    private static let uploadBaseURL = URL(
        string: "https://www.googleapis.com/upload/drive/v3/files"
    )!
    private static let folderMIMEType = "application/vnd.google-apps.folder"
    private static let maximumDiscoveryPages = 100

    private let tokenProvider: TokenProvider
    private let metadataStore: DriveMetadataStore
    private let session: URLSession
    private let uploadTransport: any DriveUploadTransport

    nonisolated static func makeMetadataSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private var activeAccountID: String?
    private var activeFolderIdentity: DriveFolderIdentity?
    private var activeDestinationScopeID: String?
    private var activationGeneration: UInt64 = 0
    private var didLogManagedFolders = false
    private var upsertQueues: [UpsertQueueKey: UpsertQueueState] = [:]
    private var folderReservations: [String: FolderReservation] = [:]
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.uinaf.healthmule",
        category: "drive"
    )

    init(
        tokenProvider: @escaping TokenProvider,
        metadataStore: DriveMetadataStore,
        session: URLSession = DriveAPIClient.makeMetadataSession(),
        uploadTransport: any DriveUploadTransport
    ) {
        self.tokenProvider = tokenProvider
        self.metadataStore = metadataStore
        self.session = session
        self.uploadTransport = uploadTransport
    }

    @discardableResult
    func activateAccount(
        _ accountID: String,
        folders: DriveFolderConnection
    ) async throws -> DriveAccountActivation {
        let destinationScopeID = DriveMetadataStore.destinationNamespace(
            for: accountID,
            rootID: folders.rootID,
            dailyID: folders.dailyID
        )
        activationGeneration &+= 1
        let expectedGeneration = activationGeneration
        clearActiveDestination()
        try await transitionUploadDestination(
            to: destinationScopeID,
            expectedGeneration: expectedGeneration
        )
        guard activationGeneration == expectedGeneration else {
            throw DriveAPIError.accountNotReady
        }
        try Task.checkCancellation()
        activeAccountID = accountID
        activeFolderIdentity = DriveFolderIdentity(folders)
        activeDestinationScopeID = destinationScopeID
        return DriveAccountActivation(
            accountID: accountID,
            generation: expectedGeneration
        )
    }

    func clearActiveAccount() async throws {
        activationGeneration &+= 1
        let expectedGeneration = activationGeneration
        clearActiveDestination()
        try await transitionUploadDestination(
            to: nil,
            expectedGeneration: expectedGeneration
        )
    }

    func clearActiveAccount(
        ifMatching activation: DriveAccountActivation
    ) async throws {
        guard
            activeAccountID == activation.accountID,
            activationGeneration == activation.generation
        else {
            return
        }
        activationGeneration &+= 1
        let expectedGeneration = activationGeneration
        clearActiveDestination()
        try await transitionUploadDestination(
            to: nil,
            expectedGeneration: expectedGeneration
        )
    }

    func ensureAppFolders(
        for accountID: String
    ) async throws -> DriveFolderConnection {
        try Task.checkCancellation()
        let reservation: FolderReservation
        if var existing = folderReservations[accountID] {
            existing.callerCount += 1
            folderReservations[accountID] = existing
            reservation = existing
        } else {
            let reservationID = UUID()
            let task = Task<DriveFolderConnection, Error> {
                try await self.performEnsureAppFolders(for: accountID)
            }
            reservation = FolderReservation(
                id: reservationID,
                task: task,
                callerCount: 1
            )
            folderReservations[accountID] = reservation
        }
        let resultGate = ResultGate<DriveFolderConnection>()
        Task {
            resultGate.resolve(await reservation.task.result)
        }

        defer {
            releaseFolderReservation(
                for: accountID,
                reservationID: reservation.id
            )
        }
        return try await withTaskCancellationHandler {
            let connection = try await resultGate.wait()
            try Task.checkCancellation()
            return connection
        } onCancel: {
            resultGate.cancel()
        }
    }

    private func performEnsureAppFolders(
        for accountID: String
    ) async throws -> DriveFolderConnection {
        try Task.checkCancellation()
        let folderSet = await metadataStore.folders(for: accountID)

        let root = try await ensureFolder(
            cachedID: folderSet.rootID,
            name: "Apple Health Sync",
            parentID: "root",
            kind: "root",
            accountID: accountID
        )

        let daily = try await ensureFolder(
            cachedID: folderSet.dailyID,
            name: "daily",
            parentID: root.id,
            kind: "daily-folder",
            accountID: accountID
        )
        await metadataStore.commitFolders(
            rootID: root.id,
            dailyID: daily.id,
            for: accountID
        )
        if !didLogManagedFolders {
            logger.info(
                "managed folders ready rootID=\(root.id, privacy: .private(mask: .hash)) dailyID=\(daily.id, privacy: .private(mask: .hash))"
            )
            didLogManagedFolders = true
        }

        return DriveFolderConnection(
            rootID: root.id,
            dailyID: daily.id,
            name: root.name ?? "Apple Health Sync"
        )
    }

    func ensureAppFoldersForActiveAccount() async throws
        -> DriveFolderConnection
    {
        guard
            let accountID = activeAccountID,
            let expectedFolders = activeFolderIdentity
        else {
            throw DriveAPIError.accountNotReady
        }
        let expectedGeneration = activationGeneration
        let verifiedFolders = try await ensureAppFolders(for: accountID)
        guard
            activeAccountID == accountID,
            activeFolderIdentity == expectedFolders,
            activationGeneration == expectedGeneration
        else {
            throw DriveAPIError.accountNotReady
        }
        guard DriveFolderIdentity(verifiedFolders) == expectedFolders else {
            throw DriveAPIError.destinationChanged
        }
        return verifiedFolders
    }

    @discardableResult
    func upsertJSON(
        named name: String,
        parentID: String,
        kind: String,
        date: String?,
        data: Data
    ) async throws -> DriveRemoteItem {
        try Task.checkCancellation()
        guard
            let accountID = activeAccountID,
            let activeFolderIdentity,
            let destinationScopeID = activeDestinationScopeID
        else {
            throw DriveAPIError.accountNotReady
        }
        let expectedActivationGeneration = activationGeneration
        let expectedParentID = kind == "daily"
            ? activeFolderIdentity.dailyID
            : activeFolderIdentity.rootID
        guard parentID == expectedParentID else {
            throw DriveAPIError.destinationChanged
        }
        let cacheKey = [kind, date].compactMap { $0 }.joined(separator: ":")
        let queueKey = UpsertQueueKey(
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            cacheKey: cacheKey
        )
        let reservationID = UUID()
        let predecessor = upsertQueues[queueKey]?.tail
        let operation = Task<DriveRemoteItem, Error> {
            if let predecessor {
                await predecessor.value
            }
            try Task.checkCancellation()
            return try await self.performUpsertJSON(
                named: name,
                parentID: parentID,
                kind: kind,
                date: date,
                data: data,
                cacheKey: cacheKey,
                accountID: accountID,
                folderIdentity: activeFolderIdentity,
                destinationScopeID: destinationScopeID,
                expectedActivationGeneration:
                    expectedActivationGeneration
            )
        }
        let tail = Task<Void, Never> {
            _ = await operation.result
        }
        var reservationIDs =
            upsertQueues[queueKey]?.reservationIDs ?? []
        reservationIDs.insert(reservationID)
        upsertQueues[queueKey] = UpsertQueueState(
            tail: tail,
            reservationIDs: reservationIDs
        )
        let resultGate = ResultGate<DriveRemoteItem>()
        Task {
            resultGate.resolve(await operation.result)
            releaseUpsertReservation(
                for: queueKey,
                reservationID: reservationID
            )
        }
        return try await withTaskCancellationHandler {
            let item = try await resultGate.wait()
            try Task.checkCancellation()
            return item
        } onCancel: {
            operation.cancel()
            resultGate.cancel()
        }
    }

    private func performUpsertJSON(
        named name: String,
        parentID: String,
        kind: String,
        date: String?,
        data: Data,
        cacheKey: String,
        accountID: String,
        folderIdentity: DriveFolderIdentity,
        destinationScopeID: String,
        expectedActivationGeneration: UInt64
    ) async throws -> DriveRemoteItem {
        try Task.checkCancellation()
        try ensureActiveDestination(
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            activationGeneration: expectedActivationGeneration
        )
        guard activeFolderIdentity == folderIdentity else {
            throw DriveAPIError.accountNotReady
        }
        let expectedParentID = kind == "daily"
            ? folderIdentity.dailyID
            : folderIdentity.rootID
        guard parentID == expectedParentID else {
            throw DriveAPIError.destinationChanged
        }
        let cacheSnapshot = await metadataStore.fileIDSnapshot(
            for: cacheKey,
            accountID: accountID
        )
        let destinationGeneration = cacheSnapshot.destinationGeneration
        var existingFileID: String?
        var reservedCreateFileID: String?

        if let cachedFileID = cacheSnapshot.fileID {
            do {
                let cachedItem = try await fetchItem(
                    id: cachedFileID,
                    accountID: accountID
                )
                if Self.isUsableJSONArtifact(
                    cachedItem,
                    parentID: parentID,
                    kind: kind,
                    date: date
                ) {
                    existingFileID = cachedFileID
                } else {
                    guard await metadataStore.removeFileID(
                        for: cacheKey,
                        accountID: accountID,
                        ifDestinationGeneration: destinationGeneration
                    ) else {
                        throw DriveAPIError.accountNotReady
                    }
                }
            } catch DriveAPIError.remote(let status, _, _)
                where status == 404
            {
                if cacheSnapshot.status == .pendingCreate {
                    // A pre-generated ID is cached before its background
                    // create is scheduled. A transient 404 can therefore mean
                    // that create is still in flight.
                    reservedCreateFileID = cachedFileID
                } else {
                    guard await metadataStore.removeFileID(
                        for: cacheKey,
                        accountID: accountID,
                        ifDestinationGeneration: destinationGeneration
                    ) else {
                        throw DriveAPIError.accountNotReady
                    }
                }
            }
        }

        if existingFileID == nil, reservedCreateFileID == nil {
            existingFileID = try await findTaggedItem(
                parentID: parentID,
                kind: kind,
                date: date,
                accountID: accountID
            )?.id
        }

        if let existingFileID {
            do {
                return try await updateExistingJSON(
                    fileID: existingFileID,
                    name: name,
                    parentID: parentID,
                    kind: kind,
                    date: date,
                    data: data,
                    accountID: accountID,
                    destinationScopeID: destinationScopeID,
                    expectedActivationGeneration:
                        expectedActivationGeneration,
                    cacheKey: cacheKey,
                    destinationGeneration: destinationGeneration
                )
            } catch DriveAPIError.remote(let status, _, _) where status == 404 {
                guard await metadataStore.removeFileID(
                    for: cacheKey,
                    accountID: accountID,
                    ifDestinationGeneration: destinationGeneration
                ) else {
                    throw DriveAPIError.accountNotReady
                }
                if
                    let rediscovered = try await findTaggedItem(
                        parentID: parentID,
                        kind: kind,
                        date: date,
                        accountID: accountID
                    )
                {
                    do {
                        return try await updateExistingJSON(
                            fileID: rediscovered.id,
                            name: name,
                            parentID: parentID,
                            kind: kind,
                            date: date,
                            data: data,
                            accountID: accountID,
                            destinationScopeID: destinationScopeID,
                            expectedActivationGeneration:
                                expectedActivationGeneration,
                            cacheKey: cacheKey,
                            destinationGeneration:
                                destinationGeneration
                        )
                    } catch DriveAPIError.remote(
                        let rediscoveredStatus,
                        _,
                        _
                    ) where rediscoveredStatus == 404 {
                        guard await metadataStore.removeFileID(
                            for: cacheKey,
                            accountID: accountID,
                            ifDestinationGeneration:
                                destinationGeneration
                        ) else {
                            throw DriveAPIError.accountNotReady
                        }
                    }
                }
            }
        }

        let createFileID: String
        if let reservedCreateFileID {
            guard await metadataStore.isCurrentDestinationGeneration(
                destinationGeneration,
                for: accountID
            ) else {
                throw DriveAPIError.accountNotReady
            }
            createFileID = reservedCreateFileID
        } else {
            createFileID = try await generateFileID(accountID: accountID)
            guard await metadataStore.reserveFileID(
                createFileID,
                for: cacheKey,
                accountID: accountID,
                ifDestinationGeneration: destinationGeneration
            ) else {
                throw DriveAPIError.accountNotReady
            }
        }
        try ensureActiveDestination(
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            activationGeneration: expectedActivationGeneration
        )
        do {
            let item = try await multipartUpload(
                fileID: createFileID,
                name: name,
                parentID: parentID,
                kind: kind,
                date: date,
                data: data,
                isCreate: true,
                accountID: accountID,
                destinationScopeID: destinationScopeID,
                expectedActivationGeneration: expectedActivationGeneration
            )
            guard await metadataStore.setFileID(
                item.id,
                for: cacheKey,
                accountID: accountID,
                ifDestinationGeneration: destinationGeneration
            ) else {
                throw DriveAPIError.accountNotReady
            }
            try ensureActiveDestination(
                accountID: accountID,
                destinationScopeID: destinationScopeID,
                activationGeneration: expectedActivationGeneration
            )
            logUpsert(itemID: item.id, kind: kind)
            return item
        } catch DriveAPIError.remote(let status, _, _) where status == 409 {
            let item: DriveRemoteItem
            do {
                item = try await multipartUpload(
                    fileID: createFileID,
                    name: name,
                    parentID: parentID,
                    kind: kind,
                    date: date,
                    data: data,
                    isCreate: false,
                    accountID: accountID,
                    destinationScopeID: destinationScopeID,
                    expectedActivationGeneration:
                        expectedActivationGeneration
                )
            } catch DriveAPIError.remote(let patchStatus, _, _)
                where patchStatus == 404
            {
                // The create may still be completing remotely. Keep the
                // pending reservation and retry without allocating a new ID.
                throw DriveAPIError.accountNotReady
            }
            guard await metadataStore.setFileID(
                item.id,
                for: cacheKey,
                accountID: accountID,
                ifDestinationGeneration: destinationGeneration
            ) else {
                throw DriveAPIError.accountNotReady
            }
            try ensureActiveDestination(
                accountID: accountID,
                destinationScopeID: destinationScopeID,
                activationGeneration: expectedActivationGeneration
            )
            logUpsert(itemID: item.id, kind: kind)
            return item
        }
    }

    private func updateExistingJSON(
        fileID: String,
        name: String,
        parentID: String,
        kind: String,
        date: String?,
        data: Data,
        accountID: String,
        destinationScopeID: String,
        expectedActivationGeneration: UInt64,
        cacheKey: String,
        destinationGeneration: UInt64
    ) async throws -> DriveRemoteItem {
        let item = try await multipartUpload(
            fileID: fileID,
            name: name,
            parentID: parentID,
            kind: kind,
            date: date,
            data: data,
            isCreate: false,
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            expectedActivationGeneration: expectedActivationGeneration
        )
        guard await metadataStore.setFileID(
            item.id,
            for: cacheKey,
            accountID: accountID,
            ifDestinationGeneration: destinationGeneration
        ) else {
            throw DriveAPIError.accountNotReady
        }
        try ensureActiveDestination(
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            activationGeneration: expectedActivationGeneration
        )
        logUpsert(itemID: item.id, kind: kind)
        return item
    }

    private func ensureFolder(
        cachedID: String?,
        name: String,
        parentID: String,
        kind: String,
        accountID: String
    ) async throws -> DriveRemoteItem {
        if let cachedID {
            do {
                let item = try await fetchItem(
                    id: cachedID,
                    accountID: accountID
                )
                if Self.isUsableFolder(
                    item,
                    kind: kind,
                    requiredParentID: requiredParentID(
                        kind: kind,
                        parentID: parentID
                    )
                ) {
                    return item
                }
            } catch DriveAPIError.remote(let status, _, _) where status == 404 {
                // Retry the same pre-generated ID below before choosing a new one.
                do {
                    let item = try await createFolder(
                        id: cachedID,
                        name: name,
                        parentID: parentID,
                        kind: kind,
                        accountID: accountID
                    )
                    if Self.isUsableFolder(
                        item,
                        kind: kind,
                        requiredParentID: requiredParentID(
                            kind: kind,
                            parentID: parentID
                        )
                    ) {
                        return item
                    }
                } catch DriveAPIError.remote(let status, _, _) where status == 409 {
                    do {
                        let item = try await fetchItem(
                            id: cachedID,
                            accountID: accountID
                        )
                        if Self.isUsableFolder(
                            item,
                            kind: kind,
                            requiredParentID: requiredParentID(
                                kind: kind,
                                parentID: parentID
                            )
                        ) {
                            return item
                        }
                    } catch DriveAPIError.remote(let fetchStatus, _, _)
                        where fetchStatus == 404
                    {
                        // A crash may leave a cached pre-generated ID that no
                        // longer resolves. Fall through and choose a fresh ID.
                    }
                }
            }
            await clearFolderID(kind: kind, accountID: accountID)
        }

        if let existing = try await findTaggedItem(
            parentID: parentID,
            kind: kind,
            date: nil,
            accountID: accountID
        ) {
            return existing
        }

        let id = try await generateFileID(accountID: accountID)
        if kind == "root" {
            await metadataStore.setRootID(id, for: accountID)
        } else {
            await metadataStore.setDailyID(id, for: accountID)
        }
        do {
            return try await createFolder(
                id: id,
                name: name,
                parentID: parentID,
                kind: kind,
                accountID: accountID
            )
        } catch DriveAPIError.remote(let status, _, _) where status == 409 {
            let item = try await fetchItem(id: id, accountID: accountID)
            guard
                Self.isUsableFolder(
                    item,
                    kind: kind,
                    requiredParentID: requiredParentID(
                        kind: kind,
                        parentID: parentID
                    )
                )
            else {
                await clearFolderID(kind: kind, accountID: accountID)
                throw DriveAPIError.invalidResponse
            }
            return item
        }
    }

    private func findTaggedItem(
        parentID: String,
        kind: String,
        date: String?,
        accountID: String
    ) async throws -> DriveRemoteItem? {
        var clauses = [
            "trashed = false",
            "appProperties has { key='healthMuleKind' and value='\(escapedQueryValue(kind))' }",
        ]
        if kind != "root" {
            clauses.insert(
                "'\(escapedQueryValue(parentID))' in parents",
                at: 0
            )
        }
        if kind == "root" || kind == "daily-folder" {
            clauses.append("mimeType = '\(Self.folderMIMEType)'")
        } else {
            clauses.append("mimeType = 'application/json'")
        }
        if let date {
            clauses.append(
                "appProperties has { key='healthMuleDate' and value='\(escapedQueryValue(date))' }"
            )
        }

        let baseQueryItems = [
            URLQueryItem(name: "q", value: clauses.joined(separator: " and ")),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,files(id,name,webViewLink,appProperties,mimeType,trashed,parents)"
            ),
            URLQueryItem(name: "pageSize", value: "10"),
        ]

        var pageToken: String?
        var seenPageTokens: Set<String> = []
        for _ in 0..<Self.maximumDiscoveryPages {
            var components = URLComponents(
                url: Self.filesBaseURL,
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = baseQueryItems
            if let pageToken {
                components.queryItems?.append(
                    URLQueryItem(name: "pageToken", value: pageToken)
                )
            }

            let data = try await request(
                url: components.url!,
                method: "GET",
                accountID: accountID
            )
            let page = try JSONDecoder().decode(
                FileListResponse.self,
                from: data
            )
            if kind == "root" || kind == "daily-folder" {
                let requiredParent = requiredParentID(
                    kind: kind,
                    parentID: parentID
                )
                if let item = page.files.first(where: {
                    Self.isUsableFolder(
                        $0,
                        kind: kind,
                        requiredParentID: requiredParent
                    )
                }) {
                    return item
                }
            } else if let item = page.files.first(where: {
                Self.isUsableJSONArtifact(
                    $0,
                    parentID: parentID,
                    kind: kind,
                    date: date
                )
            }) {
                return item
            }

            guard
                let nextPageToken = page.nextPageToken,
                !nextPageToken.isEmpty
            else {
                return nil
            }
            guard seenPageTokens.insert(nextPageToken).inserted else {
                throw DriveAPIError.invalidResponse
            }
            pageToken = nextPageToken
        }

        throw DriveAPIError.invalidResponse
    }

    private func fetchItem(
        id: String,
        accountID: String
    ) async throws -> DriveRemoteItem {
        var components = URLComponents(
            url: Self.filesBaseURL.appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "id,name,webViewLink,appProperties,mimeType,trashed,parents"
            )
        ]
        let data = try await request(
            url: components.url!,
            method: "GET",
            accountID: accountID
        )
        return try JSONDecoder().decode(DriveRemoteItem.self, from: data)
    }

    private func generateFileID(accountID: String) async throws -> String {
        var components = URLComponents(
            url: Self.filesBaseURL.appendingPathComponent("generateIds"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "space", value: "drive"),
            URLQueryItem(name: "type", value: "files"),
        ]
        let data = try await request(
            url: components.url!,
            method: "GET",
            accountID: accountID
        )
        guard let id = try JSONDecoder()
            .decode(GenerateIDsResponse.self, from: data)
            .ids.first
        else {
            throw DriveAPIError.invalidResponse
        }
        return id
    }

    private func createFolder(
        id: String,
        name: String,
        parentID: String,
        kind: String,
        accountID: String
    ) async throws -> DriveRemoteItem {
        let payload = DriveCreateMetadata(
            id: id,
            name: name,
            mimeType: Self.folderMIMEType,
            parents: [parentID],
            appProperties: ["healthMuleKind": kind]
        )
        var components = URLComponents(
            url: Self.filesBaseURL,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "id,name,webViewLink,appProperties,mimeType,trashed,parents"
            )
        ]
        let body = try JSONEncoder().encode(payload)
        let data = try await request(
            url: components.url!,
            method: "POST",
            body: body,
            contentType: "application/json",
            accountID: accountID
        )
        let item = try JSONDecoder().decode(DriveRemoteItem.self, from: data)
        guard
            Self.isUsableFolder(
                item,
                kind: kind,
                requiredParentID: requiredParentID(
                    kind: kind,
                    parentID: parentID
                )
            )
        else {
            throw DriveAPIError.invalidResponse
        }
        return item
    }

    private func multipartUpload(
        fileID: String,
        name: String,
        parentID: String,
        kind: String,
        date: String?,
        data: Data,
        isCreate: Bool,
        accountID: String,
        destinationScopeID: String,
        expectedActivationGeneration: UInt64
    ) async throws -> DriveRemoteItem {
        let boundary = "healthmule-\(UUID().uuidString)"
        var appProperties = ["healthMuleKind": kind]
        if let date {
            appProperties["healthMuleDate"] = date
        }
        let metadata = DriveCreateMetadata(
            id: isCreate ? fileID : nil,
            name: name,
            mimeType: "application/json",
            parents: isCreate ? [parentID] : nil,
            appProperties: appProperties
        )
        let metadataData = try JSONEncoder().encode(metadata)

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataData)
        body.appendUTF8("\r\n--\(boundary)\r\n")
        body.appendUTF8("Content-Type: application/json\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        let baseURL = isCreate
            ? Self.uploadBaseURL
            : Self.uploadBaseURL.appendingPathComponent(fileID)
        var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(
                name: "fields",
                value: "id,name,webViewLink,appProperties"
            ),
        ]
        let response = try await request(
            url: components.url!,
            method: isCreate ? "POST" : "PATCH",
            body: body,
            contentType: "multipart/related; boundary=\(boundary)",
            accountID: accountID,
            uploadOperationID: Self.uploadOperationID(
                accountID: accountID,
                fileID: fileID,
                method: isCreate ? "POST" : "PATCH",
                name: name,
                parentID: parentID,
                kind: kind,
                date: date,
                data: data
            ),
            uploadDestinationScopeID: destinationScopeID,
            uploadActivationGeneration: expectedActivationGeneration
        )
        return try JSONDecoder().decode(DriveRemoteItem.self, from: response)
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        accountID: String,
        uploadOperationID: String? = nil,
        uploadDestinationScopeID: String? = nil,
        uploadActivationGeneration: UInt64? = nil
    ) async throws -> Data {
        let attemptCount = uploadOperationID == nil ? 1 : 2
        for attempt in 0..<attemptCount {
            let token = try await accessToken(for: accountID)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
            if let contentType {
                request.setValue(
                    contentType,
                    forHTTPHeaderField: "Content-Type"
                )
            }

            let data: Data
            let response: URLResponse
            do {
                if let uploadOperationID {
                    guard
                        let body,
                        let uploadDestinationScopeID,
                        let uploadActivationGeneration
                    else {
                        if body == nil {
                            throw DriveAPIError.invalidResponse
                        }
                        throw DriveAPIError.accountNotReady
                    }
                    try ensureActiveDestination(
                        accountID: accountID,
                        destinationScopeID: uploadDestinationScopeID,
                        activationGeneration: uploadActivationGeneration
                    )
                    var uploadRequest = request
                    uploadRequest.httpBody = nil
                    let operationID = attempt == 0
                        ? uploadOperationID
                        : Self.refreshedTokenRetryOperationID(
                            uploadOperationID
                        )
                    let uploadResponse = try await uploadTransport.upload(
                        request: uploadRequest,
                        body: body,
                        operationID: operationID,
                        destinationScopeID: uploadDestinationScopeID
                    )
                    try ensureActiveDestination(
                        accountID: accountID,
                        destinationScopeID: uploadDestinationScopeID,
                        activationGeneration: uploadActivationGeneration
                    )
                    data = uploadResponse.data
                    response = uploadResponse.response
                } else {
                    (data, response) = try await session.data(for: request)
                }
            } catch let error as URLError {
                throw DriveAPIError.transport(code: error.code)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DriveAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 {
                    if uploadOperationID != nil, attempt == 0 {
                        continue
                    }
                    throw DriveAPIError.reauthorizationRequired
                }
                let reason = try? JSONDecoder()
                    .decode(DriveErrorEnvelope.self, from: data)
                    .error.errors?.first?.reason
                let retryable = Self.isRetryable(
                    status: httpResponse.statusCode,
                    reason: reason
                )
                throw DriveAPIError.remote(
                    status: httpResponse.statusCode,
                    reason: reason,
                    retryable: retryable
                )
            }
            return data
        }
        throw DriveAPIError.invalidResponse
    }

    private func accessToken(for accountID: String) async throws -> String {
        do {
            return try await tokenProvider(accountID)
        } catch let error as GoogleAuthError {
            switch error {
            case
                .identityUnavailable,
                .signedOut,
                .scopeNotGranted,
                .reauthorizationRequired:
                throw DriveAPIError.reauthorizationRequired
            case .accountChanged:
                throw DriveAPIError.accountNotReady
            case
                .configurationMissing,
                .presenterUnavailable,
                .refreshTemporarilyUnavailable:
                throw DriveAPIError.authenticationUnavailable
            }
        } catch let error as URLError {
            throw DriveAPIError.transport(code: error.code)
        } catch {
            throw DriveAPIError.authenticationUnavailable
        }
    }

    private func clearActiveDestination() {
        activeAccountID = nil
        activeFolderIdentity = nil
        activeDestinationScopeID = nil
    }

    private func ensureActiveDestination(
        accountID: String,
        destinationScopeID: String,
        activationGeneration expectedGeneration: UInt64
    ) throws {
        guard
            activationGeneration == expectedGeneration,
            activeAccountID == accountID,
            activeDestinationScopeID == destinationScopeID
        else {
            throw DriveAPIError.accountNotReady
        }
    }

    private func releaseUpsertReservation(
        for key: UpsertQueueKey,
        reservationID: UUID
    ) {
        guard
            var queue = upsertQueues[key],
            queue.reservationIDs.remove(reservationID) != nil
        else {
            return
        }
        if queue.reservationIDs.isEmpty {
            upsertQueues.removeValue(forKey: key)
        } else {
            upsertQueues[key] = queue
        }
    }

    private func releaseFolderReservation(
        for accountID: String,
        reservationID: UUID
    ) {
        guard
            var reservation = folderReservations[accountID],
            reservation.id == reservationID
        else {
            return
        }
        reservation.callerCount -= 1
        if reservation.callerCount == 0 {
            folderReservations.removeValue(forKey: accountID)
            reservation.task.cancel()
        } else {
            folderReservations[accountID] = reservation
        }
    }

#if DEBUG
    func pendingUpsertCount(
        accountID: String,
        destinationScopeID: String,
        cacheKey: String
    ) -> Int {
        upsertQueues[
            UpsertQueueKey(
                accountID: accountID,
                destinationScopeID: destinationScopeID,
                cacheKey: cacheKey
            )
        ]?.reservationIDs.count ?? 0
    }

    func folderReservationCallerCount(for accountID: String) -> Int {
        folderReservations[accountID]?.callerCount ?? 0
    }
#endif

    private func transitionUploadDestination(
        to destinationScopeID: String?,
        expectedGeneration: UInt64
    ) async throws {
        do {
            try await uploadTransport.transition(
                toDestinationScopeID: destinationScopeID
            )
        } catch is CancellationError {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw DriveAPIError.accountNotReady
        } catch let error as URLError {
            throw DriveAPIError.transport(code: error.code)
        } catch {
            throw DriveAPIError.transport(code: .unknown)
        }
        guard activationGeneration == expectedGeneration else {
            throw DriveAPIError.accountNotReady
        }
    }

    private func escapedQueryValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func logUpsert(itemID: String, kind: String) {
        logger.info(
            "upsert completed kind=\(kind, privacy: .public) fileID=\(itemID, privacy: .private(mask: .hash))"
        )
    }

    private func clearFolderID(kind: String, accountID: String) async {
        if kind == "root" {
            await metadataStore.removeRootID(for: accountID)
        } else {
            await metadataStore.removeDailyID(for: accountID)
        }
    }

    private func requiredParentID(
        kind: String,
        parentID: String
    ) -> String? {
        kind == "daily-folder" ? parentID : nil
    }

    private static func isUsableFolder(
        _ item: DriveRemoteItem,
        kind: String,
        requiredParentID: String?
    ) -> Bool {
        guard
            item.mimeType == folderMIMEType,
            item.trashed != true
        else {
            return false
        }
        if kind == "root", item.parents?.isEmpty != false {
            return false
        }
        guard let requiredParentID else {
            return true
        }
        return item.parents?.contains(requiredParentID) == true
    }

    private static func isUsableJSONArtifact(
        _ item: DriveRemoteItem,
        parentID: String,
        kind: String,
        date: String?
    ) -> Bool {
        guard
            item.mimeType == "application/json",
            item.trashed == false,
            item.parents == [parentID],
            item.appProperties?["healthMuleKind"] == kind
        else {
            return false
        }
        return item.appProperties?["healthMuleDate"] == date
    }

    private static func isRetryable(status: Int, reason: String?) -> Bool {
        if status == 408 || status == 429 || status >= 500 {
            return true
        }
        guard status == 403, let reason else {
            return false
        }
        return [
            "backendError",
            "rateLimitExceeded",
            "userRateLimitExceeded",
        ].contains(reason)
    }

    private static func uploadOperationID(
        accountID: String,
        fileID: String,
        method: String,
        name: String,
        parentID: String,
        kind: String,
        date: String?,
        data: Data
    ) -> String {
        var hasher = SHA256()
        for value in [
            accountID,
            fileID,
            method,
            name,
            parentID,
            kind,
            date ?? "",
        ] {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        hasher.update(data: data)
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func refreshedTokenRetryOperationID(
        _ operationID: String
    ) -> String {
        SHA256.hash(data: Data("\(operationID)|token-refresh".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct FileListResponse: Decodable {
    let files: [DriveRemoteItem]
    let nextPageToken: String?
}

private struct GenerateIDsResponse: Decodable {
    let ids: [String]
}

private struct DriveCreateMetadata: Encodable {
    let id: String?
    let name: String
    let mimeType: String
    let parents: [String]?
    let appProperties: [String: String]
}

private struct DriveErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct Detail: Decodable {
            let reason: String?
        }

        let errors: [Detail]?
    }

    let error: Body
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
