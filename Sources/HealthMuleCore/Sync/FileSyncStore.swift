import Foundation

public actor FileSyncStore {
    private struct ArtifactState: Codable, Equatable, Sendable {
        var id: ExportArtifactID
        var localRevision: Int
        var uploadedRevision: Int
        var semanticDigest: String
        var contentDigest: String
        var contentByteCount: Int
    }

    private struct PersistedState: Codable, Equatable, Sendable {
        var schemaVersion = 2
        var artifacts: [String: ArtifactState] = [:]
        var retryQueue: [RetryQueueItem] = []
        var manifestNeedsRefresh = true
    }

    private struct SchemaPeek: Decodable {
        var schemaVersion: Int
    }

    private struct LegacyV1ArtifactState: Decodable {
        var id: ExportArtifactID
        var localRevision: Int
        var uploadedRevision: Int
        var semanticData: Data
        var contentData: Data?
    }

    private struct LegacyV1PersistedState: Decodable {
        var schemaVersion: Int
        var artifacts: [String: LegacyV1ArtifactState]
        var retryQueue: [RetryQueueItem]
        var manifestNeedsRefresh: Bool
    }

    private let rootDirectory: URL
    private let dailyDirectory: URL
    private let stateFile: URL
    private let v1BackupFile: URL
    private var state: PersistedState
    private var hasRecovered = false
    private var dailyRecordsByDate: [LocalDate: DailyHealthRecord] = [:]

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        dailyDirectory = rootDirectory.appendingPathComponent("daily", isDirectory: true)
        stateFile = rootDirectory.appendingPathComponent("sync-state.json", isDirectory: false)
        v1BackupFile = rootDirectory.appendingPathComponent(
            "sync-state.v1.json",
            isDirectory: false
        )
        state = PersistedState()
    }

    public func recover() throws {
        try ensureRecovered()
    }

    public func stageDaily(_ candidate: DailyHealthRecord) throws -> StageResult {
        try ensureRecovered()
        let id = ExportArtifactID.daily(candidate.date)
        let url = artifactURL(for: id)

        var record = candidate
        var canonicalContents: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let priorContents = try Data(contentsOf: url)
            let prior = try DailyHealthRecordCodec.decode(priorContents)
            record = candidate.preservingUnknownFields(from: prior)
            record = try Self.renderingTimestamps(
                in: record,
                timeZoneIdentifier: prior.timeZone
            )
            let candidateContents = try DailyHealthRecordCodec.encode(record)
            if try DailyHealthRecordCodec.semanticallyEqual(prior, record) {
                let normalizedPriorContents = try DailyHealthRecordCodec.encode(
                    prior
                )
                if priorContents == normalizedPriorContents {
                    let priorSemanticData =
                        try DailyHealthRecordCodec.semanticData(for: prior)
                    if let existing = state.artifacts[id.key] {
                        guard
                            !indexedPayloadMatches(
                                existing,
                                semanticData: priorSemanticData,
                                contentData: priorContents
                            )
                        else {
                            return .unchanged(id, revision: existing.localRevision)
                        }
                        let recoveredRevision = existing.localRevision + 1
                        var nextState = state
                        nextState.artifacts[id.key] = makeArtifactState(
                            id: id,
                            localRevision: recoveredRevision,
                            uploadedRevision: existing.uploadedRevision,
                            semanticData: priorSemanticData,
                            contentData: priorContents
                        )
                        replaceRetryItem(
                            RetryQueueItem(
                                artifactID: id,
                                revision: recoveredRevision
                            ),
                            in: &nextState
                        )
                        invalidateManifest(in: &nextState)
                        try commitStagedArtifactState(nextState)
                        rememberDailyRecord(prior)
                        return .staged(
                            id,
                            revision: recoveredRevision
                        )
                    }
                    var nextState = state
                    nextState.artifacts[id.key] = makeArtifactState(
                        id: id,
                        localRevision: 1,
                        uploadedRevision: 0,
                        semanticData: priorSemanticData,
                        contentData: priorContents
                    )
                    replaceRetryItem(
                        RetryQueueItem(artifactID: id, revision: 1),
                        in: &nextState
                    )
                    invalidateManifest(in: &nextState)
                    try commitStagedArtifactState(nextState)
                    rememberDailyRecord(prior)
                    return .staged(id, revision: 1)
                }
                let priorSemanticData =
                    try DailyHealthRecordCodec.semanticData(for: prior)
                if
                    let existing = state.artifacts[id.key],
                    indexedPayloadMatches(
                        existing,
                        semanticData: priorSemanticData,
                        contentData: normalizedPriorContents
                    )
                {
                    try writeArtifactFirst(normalizedPriorContents, to: url)
                    return .unchanged(
                        id,
                        revision: existing.localRevision
                    )
                }
                canonicalContents = normalizedPriorContents
            } else {
                canonicalContents = candidateContents
            }
        }

        let contents = try canonicalContents
            ?? DailyHealthRecordCodec.encode(record)
        let semanticData = try DailyHealthRecordCodec.semanticData(for: record)
        let nextRevision = (state.artifacts[id.key]?.localRevision ?? 0) + 1
        try writeArtifactFirst(contents, to: url)

        var nextState = state
        let uploadedRevision = nextState.artifacts[id.key]?.uploadedRevision ?? 0
        nextState.artifacts[id.key] = makeArtifactState(
            id: id,
            localRevision: nextRevision,
            uploadedRevision: uploadedRevision,
            semanticData: semanticData,
            contentData: contents
        )
        replaceRetryItem(
            RetryQueueItem(artifactID: id, revision: nextRevision),
            in: &nextState
        )
        invalidateManifest(in: &nextState)
        try commitStagedArtifactState(nextState)
        rememberDailyRecord(record)
        return .staged(id, revision: nextRevision)
    }

    public func stageManifest(_ candidate: ExportManifest) throws -> StageResult {
        try ensureRecovered()
        let id = ExportArtifactID.manifest
        let url = artifactURL(for: id)
        let manifestFileExists = FileManager.default.fileExists(atPath: url.path)

        var manifest = candidate
        if manifestFileExists {
            let prior = try ExportManifestCodec.decode(Data(contentsOf: url))
            manifest = candidate.preservingUnknownFields(from: prior)
        }

        let contents = try ExportManifestCodec.encode(manifest)
        if
            let existing = state.artifacts[id.key],
            indexedPayloadMatches(
                existing,
                semanticData: contents,
                contentData: contents
            ),
            existing.localRevision > existing.uploadedRevision,
            manifestFileExists
        {
            var nextState = state
            nextState.retryQueue.removeAll {
                $0.artifactID == id
                    && $0.revision != existing.localRevision
            }
            ensureRetryItem(
                RetryQueueItem(
                    artifactID: id,
                    revision: existing.localRevision
                ),
                in: &nextState
            )
            nextState.manifestNeedsRefresh = false
            if nextState != state {
                try commit(nextState)
            }
            return .unchanged(id, revision: existing.localRevision)
        }

        let nextRevision = (state.artifacts[id.key]?.localRevision ?? 0) + 1
        try writeArtifactFirst(contents, to: url)

        var nextState = state
        let uploadedRevision = nextState.artifacts[id.key]?.uploadedRevision ?? 0
        nextState.artifacts[id.key] = makeArtifactState(
            id: id,
            localRevision: nextRevision,
            uploadedRevision: uploadedRevision,
            semanticData: contents,
            contentData: contents
        )
        replaceRetryItem(
            RetryQueueItem(artifactID: id, revision: nextRevision),
            in: &nextState
        )
        nextState.manifestNeedsRefresh = false
        try commitStagedArtifactState(nextState)
        return .staged(id, revision: nextRevision)
    }

    public func refreshPendingManifest(
        _ candidate: ExportManifest
    ) throws -> ExportArtifact {
        try ensureRecovered()
        let id = ExportArtifactID.manifest
        let url = artifactURL(for: id)
        guard
            let existing = state.artifacts[id.key],
            existing.localRevision > existing.uploadedRevision,
            state.retryQueue.contains(where: {
                $0.artifactID == id
                    && $0.revision == existing.localRevision
            }),
            FileManager.default.fileExists(atPath: url.path)
        else {
            throw FileSyncStoreError.invalidArtifact(
                "A pending manifest revision is required for refresh."
            )
        }

        let prior = try ExportManifestCodec.decode(Data(contentsOf: url))
        let manifest = candidate.preservingUnknownFields(from: prior)
        let contents = try ExportManifestCodec.encode(manifest)
        try Task.checkCancellation()
        try writeArtifactFirst(contents, to: url)

        var nextState = state
        nextState.artifacts[id.key] = makeArtifactState(
            id: id,
            localRevision: existing.localRevision,
            uploadedRevision: existing.uploadedRevision,
            semanticData: contents,
            contentData: contents
        )
        try commitStagedArtifactState(nextState)
        return ExportArtifact(
            id: id,
            revision: existing.localRevision,
            contents: contents
        )
    }

    public func dueArtifacts(
        at date: Date,
        includeDeferred: Bool = false,
        kind: ExportArtifactID.Kind? = nil
    ) throws -> [ExportArtifact] {
        try ensureRecovered()
        let dueItems = state.retryQueue
            .filter { item in
                if let kind, item.artifactID.kind != kind {
                    return false
                }
                return item.blockReason == nil
                    && (includeDeferred || item.notBefore <= date)
            }
            .sorted {
                if $0.artifactID != $1.artifactID {
                    return $0.artifactID < $1.artifactID
                }
                return $0.revision < $1.revision
            }

        return try dueItems.compactMap { item in
            guard
                let artifactState = state.artifacts[item.artifactID.key],
                artifactState.localRevision == item.revision
            else {
                return nil
            }
            let url = artifactURL(for: item.artifactID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FileSyncStoreError.missingArtifact(item.artifactID.relativePath)
            }
            return ExportArtifact(
                id: item.artifactID,
                revision: item.revision,
                contents: try Data(contentsOf: url)
            )
        }
    }

    func hasDueArtifact(
        kind: ExportArtifactID.Kind,
        at date: Date,
        includeDeferred: Bool = false
    ) throws -> Bool {
        try ensureRecovered()
        return state.retryQueue.contains { item in
            guard
                item.artifactID.kind == kind,
                item.blockReason == nil,
                includeDeferred || item.notBefore <= date,
                let artifactState = state.artifacts[item.artifactID.key]
            else {
                return false
            }
            return artifactState.localRevision == item.revision
        }
    }

    public func markUploaded(_ artifact: ExportArtifact) throws {
        try ensureRecovered()
        guard
            var artifactState = state.artifacts[artifact.id.key],
            artifactState.localRevision == artifact.revision
        else {
            return
        }

        artifactState.uploadedRevision = artifact.revision
        var nextState = state
        nextState.artifacts[artifact.id.key] = artifactState
        nextState.retryQueue.removeAll {
            $0.artifactID == artifact.id && $0.revision <= artifact.revision
        }
        try Task.checkCancellation()
        try commit(nextState)
    }

    public func markFailed(
        _ artifact: ExportArtifact,
        error: ExportDestinationError,
        now: Date,
        randomUnit: Double,
        retryPolicy: RetryPolicy
    ) throws {
        try ensureRecovered()
        guard let index = state.retryQueue.firstIndex(where: {
            $0.artifactID == artifact.id && $0.revision == artifact.revision
        }) else {
            return
        }

        var nextState = state
        var item = nextState.retryQueue[index]
        item.attemptCount += 1

        switch error {
        case let .transient(code, retryAfter):
            item.lastErrorCode = code
            item.blockReason = nil
            let policyDate = now.addingTimeInterval(
                retryPolicy.delay(
                    afterFailure: item.attemptCount,
                    randomUnit: randomUnit
                )
            )
            item.notBefore = max(policyDate, retryAfter ?? policyDate)
        case let .reauthorizationRequired(code):
            item.lastErrorCode = code
            item.blockReason = .reauthorizationRequired
        case let .permanent(code):
            item.lastErrorCode = code
            item.blockReason = .permanentFailure
        }

        nextState.retryQueue[index] = item
        try Task.checkCancellation()
        try commit(nextState)
    }

    @discardableResult
    public func unblockReauthorizationFailures(at date: Date) throws -> Bool {
        try ensureRecovered()
        var nextState = state
        var changed = false
        for index in nextState.retryQueue.indices
        where nextState.retryQueue[index].blockReason == .reauthorizationRequired {
            nextState.retryQueue[index].blockReason = nil
            nextState.retryQueue[index].notBefore = date
            changed = true
        }
        guard changed else { return false }
        try Task.checkCancellation()
        try commit(nextState)
        return true
    }

    public func retryItems() throws -> [RetryQueueItem] {
        try ensureRecovered()
        return state.retryQueue.sorted {
            if $0.artifactID != $1.artifactID {
                return $0.artifactID < $1.artifactID
            }
            return $0.revision < $1.revision
        }
    }

    public func pendingUploadCount() throws -> Int {
        try ensureRecovered()
        return state.retryQueue.count
    }

    public func enqueueCurrentDailyArtifactsForUpload() throws {
        try ensureRecovered()
        var nextState = state
        let keys = nextState.artifacts.keys.filter { key in
            nextState.artifacts[key]?.id.kind == .daily
        }
        var changed = false
        for key in keys {
            guard var artifact = nextState.artifacts[key] else { continue }
            guard artifact.localRevision == artifact.uploadedRevision else {
                continue
            }
            artifact.localRevision += 1
            nextState.artifacts[key] = artifact
            replaceRetryItem(
                RetryQueueItem(
                    artifactID: artifact.id,
                    revision: artifact.localRevision
                ),
                in: &nextState
            )
            changed = true
        }
        guard changed else { return }
        invalidateManifest(in: &nextState)
        try commit(nextState)
    }

    public func resetRemoteUploadState() throws {
        try ensureRecovered()
        var nextState = state
        let dailyKeys = nextState.artifacts.keys.filter { key in
            nextState.artifacts[key]?.id.kind == .daily
        }
        for key in dailyKeys {
            guard var artifact = nextState.artifacts[key] else { continue }
            artifact.uploadedRevision = 0
            nextState.artifacts[key] = artifact
            replaceRetryItem(
                RetryQueueItem(
                    artifactID: artifact.id,
                    revision: artifact.localRevision
                ),
                in: &nextState
            )
        }
        nextState.artifacts.removeValue(forKey: ExportArtifactID.manifest.key)
        invalidateManifest(in: &nextState)
        try commit(nextState)
    }

    public func allDailyUploadsAreCurrent() throws -> Bool {
        try ensureRecovered()
        let dailyStates = state.artifacts.values.filter { $0.id.kind == .daily }
        return !dailyStates.isEmpty
            && dailyStates.allSatisfy { $0.localRevision == $0.uploadedRevision }
    }

    public func manifestRequiresRefresh() throws -> Bool {
        try ensureRecovered()
        return state.manifestNeedsRefresh
    }

    public func hasPendingManifestUpload() throws -> Bool {
        try ensureRecovered()
        return state.retryQueue.contains { $0.artifactID.kind == .manifest }
    }

    public func allDailyDates() throws -> Set<LocalDate> {
        try ensureRecovered()
        return Set(
            state.artifacts.values.compactMap { artifact in
                guard artifact.id.kind == .daily else {
                    return nil
                }
                return artifact.id.date
            }
        )
    }

    public func allDailyRecords() throws -> [DailyHealthRecord] {
        try ensureRecovered()
        if dailyRecordsByDate.count == dailyArtifactCount {
            return dailyRecordsByDate.values.sorted { $0.date < $1.date }
        }
        let records = try state.artifacts.values
            .filter { $0.id.kind == .daily }
            .sorted { $0.id < $1.id }
            .map { artifactState -> DailyHealthRecord in
                let url = artifactURL(for: artifactState.id)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw FileSyncStoreError.missingArtifact(
                        artifactState.id.relativePath
                    )
                }
                return try DailyHealthRecordCodec.decode(Data(contentsOf: url))
            }
        dailyRecordsByDate = Dictionary(
            uniqueKeysWithValues: records.map { ($0.date, $0) }
        )
        return records
    }

    public func artifactState(
        for id: ExportArtifactID
    ) throws -> (localRevision: Int, uploadedRevision: Int)? {
        try ensureRecovered()
        return state.artifacts[id.key].map { ($0.localRevision, $0.uploadedRevision) }
    }

    private func ensureRecovered() throws {
        guard !hasRecovered else { return }
        try FileManager.default.createDirectory(
            at: dailyDirectory,
            withIntermediateDirectories: true
        )
        #if os(iOS)
        try Self.protectAndExcludeFromBackup(rootDirectory)
        try Self.protectAndExcludeFromBackup(dailyDirectory)
        #endif
        discardPartialV2Index()
        if FileManager.default.fileExists(atPath: stateFile.path) {
            let data = try Data(contentsOf: stateFile)
            do {
                state = try decodePersistedState(data)
            } catch let error as FileSyncStoreError {
                throw error
            } catch {
                state = try recoverPersistedStateFromV1Backup()
            }
        } else if FileManager.default.fileExists(atPath: v1BackupFile.path) {
            state = try recoverPersistedStateFromV1Backup()
        } else {
            state = PersistedState()
        }
        var nextState = state
        var dailyChanged = false
        var recoveredRecords: [LocalDate: DailyHealthRecord] = [:]

        let urls = try FileManager.default.contentsOfDirectory(
            at: dailyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "json" {
            let storedContents = try Data(contentsOf: url)
            let record = try DailyHealthRecordCodec.decode(storedContents)
            recoveredRecords[record.date] = record
            let contents = try DailyHealthRecordCodec.encode(record)
            let id = ExportArtifactID.daily(record.date)
            let expectedName = "\(record.date.rawValue).json"
            guard url.lastPathComponent == expectedName else {
                throw FileSyncStoreError.invalidArtifact(url.lastPathComponent)
            }
            if storedContents != contents {
                try writeArtifactFirst(contents, to: url)
            }
            let semanticData = try DailyHealthRecordCodec.semanticData(for: record)
            if let existing = nextState.artifacts[id.key] {
                if
                    !indexedPayloadMatches(
                        existing,
                        semanticData: semanticData,
                        contentData: contents
                    )
                {
                    let revision = existing.localRevision + 1
                    nextState.artifacts[id.key] = makeArtifactState(
                        id: id,
                        localRevision: revision,
                        uploadedRevision: existing.uploadedRevision,
                        semanticData: semanticData,
                        contentData: contents
                    )
                    replaceRetryItem(
                        RetryQueueItem(artifactID: id, revision: revision),
                        in: &nextState
                    )
                    dailyChanged = true
                } else if existing.localRevision > existing.uploadedRevision {
                    ensureRetryItem(
                        RetryQueueItem(artifactID: id, revision: existing.localRevision),
                        in: &nextState
                    )
                }
            } else {
                nextState.artifacts[id.key] = makeArtifactState(
                    id: id,
                    localRevision: 1,
                    uploadedRevision: 0,
                    semanticData: semanticData,
                    contentData: contents
                )
                ensureRetryItem(
                    RetryQueueItem(artifactID: id, revision: 1),
                    in: &nextState
                )
                dailyChanged = true
            }
        }

        for artifactState in nextState.artifacts.values where artifactState.id.kind == .daily {
            guard FileManager.default.fileExists(
                atPath: artifactURL(for: artifactState.id).path
            ) else {
                throw FileSyncStoreError.missingArtifact(artifactState.id.relativePath)
            }
        }

        if dailyChanged || nextState.manifestNeedsRefresh {
            invalidateManifest(in: &nextState)
        } else {
            try recoverManifest(in: &nextState)
        }

        try commit(nextState)
        dailyRecordsByDate = recoveredRecords
        hasRecovered = true
    }

    private func recoverManifest(in nextState: inout PersistedState) throws {
        let id = ExportArtifactID.manifest
        let url = artifactURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            nextState.artifacts.removeValue(forKey: id.key)
            nextState.retryQueue.removeAll { $0.artifactID == id }
            nextState.manifestNeedsRefresh = true
            return
        }
        let artifactContents = try Data(contentsOf: url)
        let manifest = try ExportManifestCodec.decode(artifactContents)
        let contents = try ExportManifestCodec.encode(manifest)
        if artifactContents != contents {
            try writeArtifactFirst(contents, to: url)
        }

        if let existing = nextState.artifacts[id.key] {
            if
                !indexedPayloadMatches(
                    existing,
                    semanticData: contents,
                    contentData: contents
                )
            {
                let pendingRefresh = existing.localRevision
                    > existing.uploadedRevision
                    && nextState.retryQueue.contains {
                        $0.artifactID == id
                            && $0.revision == existing.localRevision
                    }
                if pendingRefresh {
                    nextState.artifacts[id.key] = makeArtifactState(
                        id: id,
                        localRevision: existing.localRevision,
                        uploadedRevision: existing.uploadedRevision,
                        semanticData: contents,
                        contentData: contents
                    )
                } else {
                    let revision = existing.localRevision + 1
                    nextState.artifacts[id.key] = makeArtifactState(
                        id: id,
                        localRevision: revision,
                        uploadedRevision: existing.uploadedRevision,
                        semanticData: contents,
                        contentData: contents
                    )
                    replaceRetryItem(
                        RetryQueueItem(artifactID: id, revision: revision),
                        in: &nextState
                    )
                }
            } else if existing.localRevision > existing.uploadedRevision {
                ensureRetryItem(
                    RetryQueueItem(artifactID: id, revision: existing.localRevision),
                    in: &nextState
                )
            }
        } else {
            nextState.artifacts[id.key] = makeArtifactState(
                id: id,
                localRevision: 1,
                uploadedRevision: 0,
                semanticData: contents,
                contentData: contents
            )
            ensureRetryItem(
                RetryQueueItem(artifactID: id, revision: 1),
                in: &nextState
            )
        }
    }

    private func invalidateManifest(in nextState: inout PersistedState) {
        nextState.manifestNeedsRefresh = true
        nextState.retryQueue.removeAll { $0.artifactID.kind == .manifest }
        let id = ExportArtifactID.manifest
        if !FileManager.default.fileExists(atPath: artifactURL(for: id).path) {
            nextState.artifacts.removeValue(forKey: id.key)
        }
    }

    private func ensureRetryItem(
        _ item: RetryQueueItem,
        in nextState: inout PersistedState
    ) {
        guard !nextState.retryQueue.contains(where: {
            $0.artifactID == item.artifactID && $0.revision == item.revision
        }) else {
            return
        }
        nextState.retryQueue.append(item)
    }

    private func replaceRetryItem(
        _ item: RetryQueueItem,
        in nextState: inout PersistedState
    ) {
        nextState.retryQueue.removeAll { $0.artifactID == item.artifactID }
        nextState.retryQueue.append(item)
    }

    private func writeArtifactFirst(_ contents: Data, to url: URL) throws {
        #if os(iOS)
        try contents.write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        try Self.protectAndExcludeFromBackup(url)
        #else
        try contents.write(to: url, options: [.atomic])
        #endif
    }

    private static func renderingTimestamps(
        in candidate: DailyHealthRecord,
        timeZoneIdentifier: String
    ) throws -> DailyHealthRecord {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw SchemaValidationError.invalidTimeZone(timeZoneIdentifier)
        }
        var record = candidate
        record.timeZone = timeZoneIdentifier
        record.generatedAt = try ISO8601Timestamp(
            date: record.generatedAt.date(),
            timeZone: timeZone
        )
        for index in record.workouts.indices {
            record.workouts[index].startedAt = try ISO8601Timestamp(
                date: record.workouts[index].startedAt.date(),
                timeZone: timeZone
            )
            record.workouts[index].endedAt = try ISO8601Timestamp(
                date: record.workouts[index].endedAt.date(),
                timeZone: timeZone
            )
        }
        return record
    }

    private func commitStagedArtifactState(_ nextState: PersistedState) throws {
        do {
            try commit(nextState)
        } catch {
            hasRecovered = false
            dailyRecordsByDate = [:]
            throw error
        }
    }

    private var dailyArtifactCount: Int {
        state.artifacts.values.count { $0.id.kind == .daily }
    }

    private func rememberDailyRecord(_ record: DailyHealthRecord) {
        dailyRecordsByDate[record.date] = record
    }

    private func commit(_ nextState: PersistedState) throws {
        try Task.checkCancellation()
        let data = try CanonicalJSON.encode(nextState)
        #if os(iOS)
        try data.write(
            to: stateFile,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        try Self.protectAndExcludeFromBackup(stateFile)
        #else
        try data.write(to: stateFile, options: [.atomic])
        #endif
        state = nextState
    }

    private func artifactURL(for id: ExportArtifactID) -> URL {
        rootDirectory.appendingPathComponent(id.relativePath, isDirectory: false)
    }

    private func decodePersistedState(_ data: Data) throws -> PersistedState {
        let peek = try CanonicalJSON.decode(SchemaPeek.self, from: data)
        switch peek.schemaVersion {
        case 1:
            try preserveV1IndexIfNeeded(data)
            return try migrateV1(CanonicalJSON.decode(
                LegacyV1PersistedState.self,
                from: data
            ))
        case 2:
            return try CanonicalJSON.decode(PersistedState.self, from: data)
        default:
            throw FileSyncStoreError.unsupportedStateVersion(peek.schemaVersion)
        }
    }

    private func recoverPersistedStateFromV1Backup() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: v1BackupFile.path) else {
            return PersistedState()
        }
        let backup = try Data(contentsOf: v1BackupFile)
        return try decodePersistedState(backup)
    }

    private func preserveV1IndexIfNeeded(_ data: Data) throws {
        guard !FileManager.default.fileExists(atPath: v1BackupFile.path) else {
            return
        }
        try writeProtectedState(data, to: v1BackupFile)
    }

    private func discardPartialV2Index() {
        let temporary = rootDirectory.appendingPathComponent(
            "sync-state.v2.tmp.json",
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: temporary)
    }

    private func migrateV1(_ legacy: LegacyV1PersistedState) -> PersistedState {
        var artifacts: [String: ArtifactState] = [:]
        artifacts.reserveCapacity(legacy.artifacts.count)
        for (key, artifact) in legacy.artifacts {
            let contentData = artifact.contentData ?? artifact.semanticData
            artifacts[key] = makeArtifactState(
                id: artifact.id,
                localRevision: artifact.localRevision,
                uploadedRevision: artifact.uploadedRevision,
                semanticData: artifact.semanticData,
                contentData: contentData
            )
        }
        return PersistedState(
            schemaVersion: 2,
            artifacts: artifacts,
            retryQueue: legacy.retryQueue,
            manifestNeedsRefresh: legacy.manifestNeedsRefresh
        )
    }

    private func makeArtifactState(
        id: ExportArtifactID,
        localRevision: Int,
        uploadedRevision: Int,
        semanticData: Data,
        contentData: Data
    ) -> ArtifactState {
        ArtifactState(
            id: id,
            localRevision: localRevision,
            uploadedRevision: uploadedRevision,
            semanticDigest: SHA256Digest.hexString(of: semanticData),
            contentDigest: SHA256Digest.hexString(of: contentData),
            contentByteCount: contentData.count
        )
    }

    private func indexedPayloadMatches(
        _ existing: ArtifactState,
        semanticData: Data,
        contentData: Data
    ) -> Bool {
        existing.contentByteCount == contentData.count
            && existing.contentDigest == SHA256Digest.hexString(of: contentData)
            && existing.semanticDigest == SHA256Digest.hexString(of: semanticData)
    }

    private func writeProtectedState(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        try Self.protectAndExcludeFromBackup(url)
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    #if os(iOS)
    private static func protectAndExcludeFromBackup(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
    #endif
}
