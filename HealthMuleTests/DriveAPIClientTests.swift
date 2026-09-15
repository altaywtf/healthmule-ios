import CryptoKit
import Foundation
import HealthMuleCore
import XCTest
@testable import HealthMule

final class DriveAPIClientTests: XCTestCase {
    @MainActor
    func testManagedFolderConnectionUsesCurrentRemoteNameWithinAccount()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-123"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("root-id", for: accountID)
        await metadataStore.setDailyID("daily-id", for: accountID)

        URLProtocolStub.setHandler { request in
            guard request.httpMethod == "GET" else {
                throw StubError.unexpectedRequest(request.httpMethod ?? "nil")
            }
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

            let item: [String: Any]
            switch request.url?.path {
            case "/drive/v3/files/root-id":
                item = [
                    "id": "root-id",
                    "name": "Renamed Health Archive",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["archive-parent"],
                ]
            case "/drive/v3/files/daily-id":
                item = [
                    "id": "daily-id",
                    "name": "daily",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["root-id"],
                ]
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, try JSONSerialization.data(withJSONObject: item))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: TestSessionDriveUploadTransport(
                session: session
            )
        )

        let connection = try await client.ensureAppFolders(for: accountID)

        XCTAssertEqual(connection.rootID, "root-id")
        XCTAssertEqual(connection.dailyID, "daily-id")
        XCTAssertEqual(connection.name, "Renamed Health Archive")
    }

    @MainActor
    func testCancellingOneFolderWaiterKeepsSharedCreationRunning()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-concurrent-folders"
        let firstDiscoveryStarted = expectation(
            description: "root discovery started"
        )
        let releaseFirstDiscovery = DispatchSemaphore(value: 0)
        defer {
            releaseFirstDiscovery.signal()
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let requests = RequestCounter()
        URLProtocolStub.setHandler { request in
            let requestIndex = requests.next()
            if requestIndex == 0 {
                firstDiscoveryStarted.fulfill()
                guard
                    releaseFirstDiscovery.wait(
                        timeout: .now() + 5
                    ) == .success
                else {
                    throw URLError(.timedOut)
                }
            }

            switch requestIndex {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": ["generated-root-id"]]
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                return try Self.response(
                    for: request,
                    json: [
                        "id": "generated-root-id",
                        "name": "Apple Health Sync",
                        "mimeType":
                            "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["root"],
                        "appProperties": [
                            "healthMuleKind": "root"
                        ],
                    ]
                )
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 4:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": ["generated-daily-id"]]
                )
            case 5:
                XCTAssertEqual(request.httpMethod, "POST")
                return try Self.response(
                    for: request,
                    json: [
                        "id": "generated-daily-id",
                        "name": "daily",
                        "mimeType":
                            "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["generated-root-id"],
                        "appProperties": [
                            "healthMuleKind": "daily-folder"
                        ],
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let metadataStore = try Self.makeMetadataStore(
            suiteName: suiteName
        )
        let client = Self.makeClient(metadataStore: metadataStore)
        let first = Task {
            try await client.ensureAppFolders(for: accountID)
        }
        await fulfillment(of: [firstDiscoveryStarted], timeout: 2)
        let second = Task {
            try await client.ensureAppFolders(for: accountID)
        }
        let joinedFolderSetup =
            try await waitForFolderReservationCallerCount(
                2,
                accountID: accountID,
                client: client
            )
        XCTAssertTrue(joinedFolderSetup)
        XCTAssertEqual(requests.count, 1)

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected the second caller to cancel promptly")
        } catch is CancellationError {
            // The shared folder setup remains owned by the first caller.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requests.count, 1)

        releaseFirstDiscovery.signal()
        let firstConnection = try await first.value

        XCTAssertEqual(firstConnection.rootID, "generated-root-id")
        XCTAssertEqual(firstConnection.dailyID, "generated-daily-id")
        XCTAssertEqual(requests.count, 6)
    }

    @MainActor
    func testManagedFolderCacheIsIsolatedByAccount() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let firstAccountID = "google-user-a"
        let secondAccountID = "google-user-b"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("root-a", for: firstAccountID)
        await metadataStore.setDailyID("daily-a", for: firstAccountID)
        await metadataStore.setRootID("root-b", for: secondAccountID)
        await metadataStore.setDailyID("daily-b", for: secondAccountID)

        URLProtocolStub.setHandler { request in
            guard request.httpMethod == "GET" else {
                throw StubError.unexpectedRequest(request.httpMethod ?? "nil")
            }

            let item: [String: Any]
            switch request.url?.path {
            case "/drive/v3/files/root-a":
                item = [
                    "id": "root-a",
                    "name": "Archive A",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["archive-parent-a"],
                ]
            case "/drive/v3/files/daily-a":
                item = [
                    "id": "daily-a",
                    "name": "daily",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["root-a"],
                ]
            case "/drive/v3/files/root-b":
                item = [
                    "id": "root-b",
                    "name": "Archive B",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["archive-parent-b"],
                ]
            case "/drive/v3/files/daily-b":
                item = [
                    "id": "daily-b",
                    "name": "daily",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false,
                    "parents": ["root-b"],
                ]
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, try JSONSerialization.data(withJSONObject: item))
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let firstConnection = try await client.ensureAppFolders(
            for: firstAccountID
        )
        let secondConnection = try await client.ensureAppFolders(
            for: secondAccountID
        )

        XCTAssertEqual(firstConnection.rootID, "root-a")
        XCTAssertEqual(firstConnection.dailyID, "daily-a")
        XCTAssertEqual(firstConnection.name, "Archive A")
        XCTAssertEqual(secondConnection.rootID, "root-b")
        XCTAssertEqual(secondConnection.dailyID, "daily-b")
        XCTAssertEqual(secondConnection.name, "Archive B")
    }

    @MainActor
    func testMetadataStoreUsesHashedV2AccountNamespacesAndIgnoresV1()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let firstAccountID = "google-user-a"
        let secondAccountID = "google-user-b"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let legacyData = try JSONSerialization.data(
            withJSONObject: [
                "folders": [
                    "rootID": "legacy-root",
                    "dailyID": "legacy-daily",
                ],
                "fileIDs": ["manifest": "legacy-manifest"],
            ]
        )
        let metadataStore = try Self.makeMetadataStore(
            suiteName: suiteName,
            legacyData: legacyData
        )
        let initialFolders = await metadataStore.folders(for: firstAccountID)
        let initialFileID = await metadataStore.fileID(
            for: "manifest",
            accountID: firstAccountID
        )

        XCTAssertEqual(initialFolders, DriveFolderSet())
        XCTAssertNil(initialFileID)

        await metadataStore.setRootID("root-a", for: firstAccountID)
        await metadataStore.setDailyID("daily-a", for: firstAccountID)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: firstAccountID
        )
        await metadataStore.setRootID("root-b", for: secondAccountID)

        let firstFolders = await metadataStore.folders(for: firstAccountID)
        let secondFolders = await metadataStore.folders(for: secondAccountID)
        let secondFileID = await metadataStore.fileID(
            for: "manifest",
            accountID: secondAccountID
        )
        let persistedDefaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        let firstFileURL = Self.metadataFileURL(
            suiteName: suiteName,
            accountID: firstAccountID
        )
        let secondFileURL = Self.metadataFileURL(
            suiteName: suiteName,
            accountID: secondAccountID
        )

        XCTAssertEqual(
            firstFolders,
            DriveFolderSet(rootID: "root-a", dailyID: "daily-a")
        )
        XCTAssertEqual(
            secondFolders,
            DriveFolderSet(rootID: "root-b", dailyID: nil)
        )
        XCTAssertNil(secondFileID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFileURL.path))
        XCTAssertNil(
            persistedDefaults.data(
                forKey: Self.metadataStateKey(for: firstAccountID)
            )
        )
        XCTAssertNil(
            persistedDefaults.data(
                forKey: Self.metadataStateKey(for: secondAccountID)
            )
        )
        XCTAssertNil(
            persistedDefaults.data(
                forKey: "drive.metadata.v2.\(firstAccountID)"
            )
        )
    }

    func testDestinationNamespaceIsDeterministicAndIncludesFolderIdentity() {
        let namespace = DriveMetadataStore.destinationNamespace(
            for: "google-user-123",
            rootID: "root-id",
            dailyID: "daily-id"
        )

        XCTAssertEqual(
            namespace,
            "e0aacc87b9e57562adefeb6c6658471f267c1e73ac80b33ae34d7e05434975e7"
        )
        XCTAssertEqual(
            namespace,
            DriveMetadataStore.destinationNamespace(
                for: "google-user-123",
                rootID: "root-id",
                dailyID: "daily-id"
            )
        )
        XCTAssertNotEqual(
            namespace,
            DriveMetadataStore.destinationNamespace(
                for: "google-user-123",
                rootID: "replacement-root",
                dailyID: "daily-id"
            )
        )
        XCTAssertFalse(namespace.contains("google-user-123"))
        XCTAssertFalse(namespace.contains("root-id"))
    }

    func testPendingFolderTransitionClearsFileIDsAfterStoreReload()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("old-root", for: accountID)
        await metadataStore.setDailyID("old-daily", for: accountID)
        await metadataStore.commitFolders(
            rootID: "old-root",
            dailyID: "old-daily",
            for: accountID
        )
        await metadataStore.setFileID(
            "old-manifest",
            for: "manifest",
            accountID: accountID
        )
        await metadataStore.setFileID(
            "old-day",
            for: "daily:2026-07-23",
            accountID: accountID
        )

        // Simulate a crash after a new pre-generated root ID was persisted,
        // but before the final folder transition and cache purge committed.
        await metadataStore.setRootID("new-root", for: accountID)
        let reloadedStore = try Self.makeMetadataStore(suiteName: suiteName)
        let preCommitManifestID = await reloadedStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(preCommitManifestID, "old-manifest")

        await reloadedStore.commitFolders(
            rootID: "new-root",
            dailyID: "new-daily",
            for: accountID
        )
        let committedFolders = await reloadedStore.folders(for: accountID)
        let manifestID = await reloadedStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        let dailyID = await reloadedStore.fileID(
            for: "daily:2026-07-23",
            accountID: accountID
        )

        XCTAssertEqual(
            committedFolders,
            DriveFolderSet(rootID: "new-root", dailyID: "new-daily")
        )
        XCTAssertNil(manifestID)
        XCTAssertNil(dailyID)
    }

    func testFileIDStatusPersistsMigratesLegacyV2AndClearsOnReset()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-file-id-status"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let legacyState = try JSONSerialization.data(
            withJSONObject: [
                "folders": [
                    "rootID": NSNull(),
                    "dailyID": NSNull(),
                ],
                "fileIDs": ["manifest": "legacy-manifest-id"],
            ]
        )
        defaults.set(
            legacyState,
            forKey: Self.metadataStateKey(for: accountID)
        )

        let migratedStore = try Self.makeMetadataStore(suiteName: suiteName)
        let legacySnapshot = await migratedStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(legacySnapshot.fileID, "legacy-manifest-id")
        XCTAssertEqual(legacySnapshot.status, .committed)

        await migratedStore.reserveFileID(
            "pending-day-id",
            for: "daily:2026-07-24",
            accountID: accountID
        )
        let reloadedStore = try Self.makeMetadataStore(suiteName: suiteName)
        let pendingSnapshot = await reloadedStore.fileIDSnapshot(
            for: "daily:2026-07-24",
            accountID: accountID
        )
        XCTAssertEqual(pendingSnapshot.fileID, "pending-day-id")
        XCTAssertEqual(pendingSnapshot.status, .pendingCreate)

        await reloadedStore.commitFolders(
            rootID: "replacement-root",
            dailyID: "replacement-daily",
            for: accountID
        )
        let resetLegacySnapshot = await reloadedStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        let resetPendingSnapshot = await reloadedStore.fileIDSnapshot(
            for: "daily:2026-07-24",
            accountID: accountID
        )
        XCTAssertNil(resetLegacySnapshot.fileID)
        XCTAssertNil(resetLegacySnapshot.status)
        XCTAssertNil(resetPendingSnapshot.fileID)
        XCTAssertNil(resetPendingSnapshot.status)
        XCTAssertNil(
            UserDefaults(suiteName: suiteName)?
                .data(forKey: Self.metadataStateKey(for: accountID))
        )
    }

    @MainActor
    func testEveryRequestUsesTheActivatedAccountToken() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let requestedAccounts = StringRecorder()

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer token-for-\(accountID)"
            )
            if request.httpMethod == "GET" {
                return try Self.response(
                    for: request,
                    json: [
                        "id": "manifest-a",
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": ["root-a"],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            }
            return try Self.response(
                for: request,
                json: ["id": "manifest-a", "name": "manifest.json"]
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let client = DriveAPIClient(
            tokenProvider: { requestedAccountID in
                requestedAccounts.append(requestedAccountID)
                return "token-for-\(requestedAccountID)"
            },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: TestSessionDriveUploadTransport(
                session: session
            )
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        _ = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        XCTAssertEqual(requestedAccounts.values, [accountID, accountID])
    }

    @MainActor
    func testAccountChangedTokenIsTransientNotReady() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in throw GoogleAuthError.accountChanged },
            metadataStore: metadataStore,
            uploadTransport: TestSessionDriveUploadTransport(
                session: URLSession(configuration: .ephemeral)
            )
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        do {
            _ = try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{}".utf8)
            )
            XCTFail("Expected an account-not-ready error")
        } catch let error as DriveAPIError {
            guard case .accountNotReady = error else {
                return XCTFail("Expected accountNotReady, got \(error)")
            }
            XCTAssertTrue(error.isRetryable)
        }
    }

    @MainActor
    func testFolderTransitionRejectsDelayedOldUploadCacheWrite()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        let requestStarted = expectation(description: "old upload started")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("old-root", for: accountID)
        await metadataStore.setDailyID("old-daily", for: accountID)
        await metadataStore.commitFolders(
            rootID: "old-root",
            dailyID: "old-daily",
            for: accountID
        )
        await metadataStore.setFileID(
            "old-manifest",
            for: "manifest",
            accountID: accountID
        )

        URLProtocolStub.setHandler { request in
            if request.httpMethod == "GET" {
                return try Self.response(
                    for: request,
                    json: [
                        "id": "old-manifest",
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": ["old-root"],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(
                request.url?.path,
                "/upload/drive/v3/files/old-manifest"
            )
            requestStarted.fulfill()
            guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                throw StubError.unexpectedRequest("response release timed out")
            }
            return try Self.response(
                for: request,
                json: ["id": "old-manifest", "name": "manifest.json"]
            )
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "old-root",
                dailyID: "old-daily",
                name: "Old Archive"
            )
        )
        let oldUpload = Task {
            do {
                _ = try await client.upsertJSON(
                    named: "manifest.json",
                    parentID: "old-root",
                    kind: "manifest",
                    date: nil,
                    data: Data("{}".utf8)
                )
                return nil as DriveAPIError?
            } catch let error as DriveAPIError {
                return error
            } catch {
                XCTFail("Unexpected error: \(error)")
                return nil
            }
        }

        await fulfillment(of: [requestStarted], timeout: 5)
        await metadataStore.setRootID("new-root", for: accountID)
        await metadataStore.setDailyID("new-daily", for: accountID)
        await metadataStore.commitFolders(
            rootID: "new-root",
            dailyID: "new-daily",
            for: accountID
        )
        releaseResponse.signal()

        let error = await oldUpload.value
        guard let error else {
            return XCTFail("Expected accountNotReady")
        }
        guard case .accountNotReady = error else {
            return XCTFail("Expected accountNotReady, got \(error)")
        }
        let staleFileID = await metadataStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertNil(staleFileID)
    }

    @MainActor
    func testActiveDestinationChangeStopsPartialUploadToReplacementTree()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        let uploadAttempts = RequestCounter()
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("old-root", for: accountID)
        await metadataStore.setDailyID("old-daily", for: accountID)
        await metadataStore.commitFolders(
            rootID: "old-root",
            dailyID: "old-daily",
            for: accountID
        )

        URLProtocolStub.setHandler { request in
            if request.url?.path.hasPrefix("/upload/") == true {
                _ = uploadAttempts.next()
                throw StubError.unexpectedRequest("upload must not start")
            }
            switch request.url?.path {
            case "/drive/v3/files/old-root":
                return try Self.response(
                    for: request,
                    json: [
                        "id": "old-root",
                        "name": "Old Archive",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": true,
                    ]
                )
            case "/drive/v3/files/old-daily":
                return try Self.response(
                    for: request,
                    json: [
                        "id": "old-daily",
                        "name": "daily",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["old-root"],
                    ]
                )
            case "/drive/v3/files":
                let query = (
                    request.url?.query?.removingPercentEncoding
                ) ?? ""
                if query.contains("daily-folder") {
                    return try Self.response(
                        for: request,
                        json: [
                            "files": [[
                                "id": "new-daily",
                                "name": "daily",
                                "mimeType": "application/vnd.google-apps.folder",
                                "trashed": false,
                                "parents": ["new-root"],
                            ]]
                        ]
                    )
                }
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "new-root",
                            "name": "Replacement Archive",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["archive-parent"],
                        ]]
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "old-root",
                dailyID: "old-daily",
                name: "Old Archive"
            )
        )
        let destination = DriveArtifactDestination(driveClient: client)
        let artifact = ExportArtifact(
            id: .manifest,
            revision: 1,
            contents: Data("{}".utf8)
        )

        do {
            try await destination.upsert(artifact)
            XCTFail("Expected the changed destination to stop the upload")
        } catch let error as ExportDestinationError {
            XCTAssertEqual(
                error,
                .transient(code: "drive_destination_changed")
            )
        }
        let folders = await metadataStore.folders(for: accountID)
        XCTAssertEqual(
            folders,
            DriveFolderSet(rootID: "new-root", dailyID: "new-daily")
        )
        XCTAssertEqual(uploadAttempts.count, 0)
    }

    @MainActor
    func testMovedTaggedRootIsRediscoveredWithoutRootParentConstraint()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        let counter = RequestCounter()
        let requests = StringRecorder()
        URLProtocolStub.setHandler { request in
            guard let url = request.url else {
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
            var query: String?
            for item in components?.queryItems ?? [] where item.name == "q" {
                query = item.value
                break
            }
            guard let query else {
                throw StubError.unexpectedRequest(url.absoluteString)
            }
            requests.append(
                "\(request.httpMethod ?? "nil")|\(url.path)|\(query)"
            )
            switch counter.next() {
            case 0:
                return try Self.response(
                    for: request,
                    json: [
                        "files": [
                            [
                                "id": "orphaned-root",
                                "name": "Orphaned Archive",
                                "mimeType": "application/vnd.google-apps.folder",
                                "trashed": false,
                                "parents": [],
                                "appProperties": [
                                    "healthMuleKind": "root"
                                ],
                            ],
                            [
                                "id": "moved-root",
                                "name": "Renamed Archive",
                                "mimeType": "application/vnd.google-apps.folder",
                                "trashed": false,
                                "parents": ["archive-parent"],
                                "appProperties": [
                                    "healthMuleKind": "root"
                                ],
                            ],
                        ]
                    ]
                )
            case 1:
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "moved-daily",
                            "name": "daily",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["moved-root"],
                            "appProperties": [
                                "healthMuleKind": "daily-folder"
                            ],
                        ]]
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let connection = try await client.ensureAppFolders(for: accountID)
        let storedFolders = await metadataStore.folders(for: accountID)

        XCTAssertEqual(
            connection,
            DriveFolderConnection(
                rootID: "moved-root",
                dailyID: "moved-daily",
                name: "Renamed Archive"
            )
        )
        XCTAssertEqual(
            storedFolders,
            DriveFolderSet(rootID: "moved-root", dailyID: "moved-daily")
        )
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertTrue(requests.values[0].hasPrefix("GET|/drive/v3/files|"))
        XCTAssertTrue(requests.values[0].contains("healthMuleKind"))
        XCTAssertTrue(requests.values[0].contains("value='root'"))
        XCTAssertFalse(requests.values[0].contains("'root' in parents"))
        XCTAssertTrue(requests.values[1].hasPrefix("GET|/drive/v3/files|"))
        XCTAssertTrue(requests.values[1].contains("daily-folder"))
        XCTAssertTrue(requests.values[1].contains("'moved-root' in parents"))
        XCTAssertEqual(counter.count, 2)
    }

    @MainActor
    func testOrphanedCachedRootIsRejectedBeforeTaggedRediscovery()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("orphaned-root", for: accountID)
        let counter = RequestCounter()
        URLProtocolStub.setHandler { request in
            switch counter.next() {
            case 0:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/orphaned-root"
                )
                return try Self.response(
                    for: request,
                    json: [
                        "id": "orphaned-root",
                        "name": "Orphaned Archive",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": [],
                    ]
                )
            case 1:
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                let query = request.url?.query?.removingPercentEncoding ?? ""
                XCTAssertTrue(query.contains("value='root'"))
                XCTAssertFalse(query.contains("'root' in parents"))
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "moved-root",
                            "name": "Renamed Archive",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["archive-parent"],
                        ]]
                    ]
                )
            case 2:
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                let query = request.url?.query?.removingPercentEncoding ?? ""
                XCTAssertTrue(query.contains("daily-folder"))
                XCTAssertTrue(query.contains("'moved-root' in parents"))
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "moved-daily",
                            "name": "daily",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["moved-root"],
                        ]]
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let connection = try await client.ensureAppFolders(for: accountID)

        XCTAssertEqual(
            connection,
            DriveFolderConnection(
                rootID: "moved-root",
                dailyID: "moved-daily",
                name: "Renamed Archive"
            )
        )
        XCTAssertEqual(counter.count, 3)
    }

    @MainActor
    func testTaggedFolderDiscoveryFollowsNextPageTokens()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        let requests = StringRecorder()
        URLProtocolStub.setHandler { request in
            guard
                let url = request.url,
                let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )
            else {
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
            var query = ""
            var pageToken: String?
            var fields = ""
            for item in components.queryItems ?? [] {
                switch item.name {
                case "q":
                    query = item.value ?? ""
                case "pageToken":
                    pageToken = item.value
                case "fields":
                    fields = item.value ?? ""
                default:
                    break
                }
            }
            requests.append("\(query)|\(pageToken ?? "first")")
            XCTAssertTrue(fields.contains("nextPageToken"))

            if query.contains("value='root'") {
                if pageToken == nil {
                    return try Self.response(
                        for: request,
                        json: [
                            "files": [[
                                "id": "orphaned-root",
                                "name": "Orphaned Archive",
                                "mimeType": "application/vnd.google-apps.folder",
                                "trashed": false,
                                "parents": [],
                            ]],
                            "nextPageToken": "root-page-2",
                        ]
                    )
                }
                XCTAssertEqual(pageToken, "root-page-2")
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "moved-root",
                            "name": "Renamed Archive",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["archive-parent"],
                        ]]
                    ]
                )
            }

            XCTAssertTrue(query.contains("daily-folder"))
            if pageToken == nil {
                return try Self.response(
                    for: request,
                    json: [
                        "files": [],
                        "nextPageToken": "daily-page-2",
                    ]
                )
            }
            XCTAssertEqual(pageToken, "daily-page-2")
            return try Self.response(
                for: request,
                json: [
                    "files": [[
                        "id": "moved-daily",
                        "name": "daily",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["moved-root"],
                    ]]
                ]
            )
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let connection = try await client.ensureAppFolders(for: accountID)

        XCTAssertEqual(connection.rootID, "moved-root")
        XCTAssertEqual(connection.dailyID, "moved-daily")
        XCTAssertEqual(requests.values.count, 4)
        XCTAssertEqual(
            requests.values[0].split(separator: "|").first,
            requests.values[1].split(separator: "|").first
        )
        XCTAssertEqual(
            requests.values[2].split(separator: "|").first,
            requests.values[3].split(separator: "|").first
        )
    }

    @MainActor
    func testUncachedManifestIsRediscoveredAsJSONBeforeUpload() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        let counter = RequestCounter()
        let requests = StringRecorder()
        URLProtocolStub.setHandler { request in
            guard let url = request.url else {
                throw StubError.unexpectedRequest("nil URL")
            }
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
            var query = ""
            var pageToken: String?
            for item in components?.queryItems ?? [] where item.name == "q" {
                query = item.value ?? ""
            }
            for item in components?.queryItems ?? []
                where item.name == "pageToken"
            {
                pageToken = item.value
            }
            requests.append(
                "\(request.httpMethod ?? "nil")|\(url.path)|\(query)|\(pageToken ?? "first")"
            )
            switch counter.next() {
            case 0:
                return try Self.response(
                    for: request,
                    json: [
                        "files": [],
                        "nextPageToken": "manifest-page-2",
                    ]
                )
            case 1:
                XCTAssertEqual(pageToken, "manifest-page-2")
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "existing-manifest",
                            "name": "manifest.json",
                            "mimeType": "application/json",
                            "trashed": false,
                            "parents": ["root-a"],
                            "appProperties": [
                                "healthMuleKind": "manifest"
                            ],
                        ]]
                    ]
                )
            case 2:
                return try Self.response(
                    for: request,
                    json: [
                        "id": "existing-manifest",
                        "name": "manifest.json",
                    ]
                )
            default:
                throw StubError.unexpectedRequest(url.absoluteString)
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let item = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )
        let cachedID = await metadataStore.fileID(
            for: "manifest",
            accountID: accountID
        )

        XCTAssertEqual(item.id, "existing-manifest")
        XCTAssertEqual(cachedID, "existing-manifest")
        XCTAssertEqual(counter.count, 3)
        XCTAssertTrue(requests.values[0].hasPrefix("GET|"))
        XCTAssertTrue(
            requests.values[0].contains(
                "mimeType = 'application/json'"
            )
        )
        XCTAssertFalse(
            requests.values[0].contains(
                "application/vnd.google-apps.folder"
            )
        )
        XCTAssertTrue(
            requests.values[1].contains(
                "manifest-page-2"
            )
        )
        XCTAssertTrue(
            requests.values[2].contains(
                "/upload/drive/v3/files/existing-manifest"
            )
        )
    }

    @MainActor
    func testTrashedCachedFolderIsReplacedByUsableDiscoveredFolder()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("trashed-root", for: accountID)
        await metadataStore.setDailyID("daily-id", for: accountID)
        await metadataStore.setFileID(
            "old-manifest",
            for: "manifest",
            accountID: accountID
        )
        await metadataStore.setFileID(
            "old-day",
            for: "daily:2026-07-23",
            accountID: accountID
        )

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/drive/v3/files/trashed-root":
                return try Self.response(
                    for: request,
                    json: [
                        "id": "trashed-root",
                        "name": "Old Archive",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": true,
                    ]
                )
            case "/drive/v3/files":
                XCTAssertEqual(request.httpMethod, "GET")
                let query = request.url?.query ?? ""
                if query.contains("daily-folder") {
                    return try Self.response(
                        for: request,
                        json: [
                            "files": [[
                                "id": "replacement-daily",
                                "name": "daily",
                                "mimeType": "application/vnd.google-apps.folder",
                                "trashed": false,
                                "parents": ["replacement-root"],
                            ]]
                        ]
                    )
                }
                return try Self.response(
                    for: request,
                    json: [
                        "files": [[
                            "id": "replacement-root",
                            "name": "Current Archive",
                            "mimeType": "application/vnd.google-apps.folder",
                            "trashed": false,
                            "parents": ["archive-parent"],
                        ]]
                    ]
                )
            case "/drive/v3/files/daily-id":
                return try Self.response(
                    for: request,
                    json: [
                        "id": "daily-id",
                        "name": "daily",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["trashed-root"],
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let connection = try await client.ensureAppFolders(for: accountID)
        let storedFolders = await metadataStore.folders(for: accountID)
        let staleFileID = await metadataStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        let staleDailyFileID = await metadataStore.fileID(
            for: "daily:2026-07-23",
            accountID: accountID
        )

        XCTAssertEqual(connection.rootID, "replacement-root")
        XCTAssertEqual(connection.dailyID, "replacement-daily")
        XCTAssertEqual(connection.name, "Current Archive")
        XCTAssertEqual(storedFolders.rootID, "replacement-root")
        XCTAssertEqual(storedFolders.dailyID, "replacement-daily")
        XCTAssertNil(staleFileID)
        XCTAssertNil(staleDailyFileID)
    }

    @MainActor
    func testMissingCachedFolderCollisionFallsBackToFreshID() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setRootID("stale-root", for: accountID)
        await metadataStore.setDailyID("daily-id", for: accountID)
        let counter = RequestCounter()

        URLProtocolStub.setHandler { request in
            switch counter.next() {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files/stale-root")
                return try Self.response(for: request, status: 404, json: [:])
            case 1:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(for: request, status: 409, json: [:])
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files/stale-root")
                return try Self.response(for: request, status: 404, json: [:])
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 4:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": ["fresh-root"]]
                )
            case 5:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: [
                        "id": "fresh-root",
                        "name": "Apple Health Sync",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["drive-root"],
                    ]
                )
            case 6:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files/daily-id")
                return try Self.response(
                    for: request,
                    json: [
                        "id": "daily-id",
                        "name": "daily",
                        "mimeType": "application/vnd.google-apps.folder",
                        "trashed": false,
                        "parents": ["fresh-root"],
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let connection = try await client.ensureAppFolders(for: accountID)
        let storedFolders = await metadataStore.folders(for: accountID)

        XCTAssertEqual(connection.rootID, "fresh-root")
        XCTAssertEqual(counter.count, 7)
        XCTAssertEqual(storedFolders.rootID, "fresh-root")
    }

    @MainActor
    func testUpsertUsesActivatedAccountNamespace() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let firstAccountID = "google-user-a"
        let secondAccountID = "google-user-b"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: firstAccountID
        )
        await metadataStore.setFileID(
            "manifest-b",
            for: "manifest",
            accountID: secondAccountID
        )

        URLProtocolStub.setHandler { request in
            guard
                let itemID = request.url?.lastPathComponent,
                ["manifest-a", "manifest-b"].contains(itemID)
            else {
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
            if request.httpMethod == "GET" {
                return try Self.response(
                    for: request,
                    json: [
                        "id": itemID,
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": [
                            itemID == "manifest-a" ? "root-a" : "root-b"
                        ],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            }
            guard request.httpMethod == "PATCH" else {
                throw StubError.unexpectedRequest(request.httpMethod ?? "nil")
            }
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let data = try JSONSerialization.data(
                withJSONObject: ["id": itemID, "name": "manifest.json"]
            )
            return (response, data)
        }

        let client = Self.makeClient(metadataStore: metadataStore)
        let firstActivation = try await client.activateAccount(
            firstAccountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )
        let firstItem = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )
        try await client.activateAccount(
            secondAccountID,
            folders: DriveFolderConnection(
                rootID: "root-b",
                dailyID: "daily-b",
                name: "Archive B"
            )
        )
        try await client.clearActiveAccount(ifMatching: firstActivation)
        let secondItem = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-b",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        XCTAssertEqual(firstItem.id, "manifest-a")
        XCTAssertEqual(secondItem.id, "manifest-b")
    }

    @MainActor
    func testDestinationMapsMissingActiveAccountToTransientNotReady()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        let client = Self.makeClient(metadataStore: metadataStore)
        try await client.activateAccount(
            "google-user",
            folders: DriveFolderConnection(
                rootID: "root-id",
                dailyID: "daily-id",
                name: "Apple Health Sync"
            )
        )
        try await client.clearActiveAccount()
        let destination = DriveArtifactDestination(driveClient: client)
        let artifact = ExportArtifact(
            id: .manifest,
            revision: 1,
            contents: Data("{}".utf8)
        )

        do {
            try await destination.upsert(artifact)
            XCTFail("Expected the destination to require an active account")
        } catch let error as ExportDestinationError {
            XCTAssertEqual(
                error,
                .transient(code: "drive_account_not_ready")
            )
        }
    }

    @MainActor
    func testCancelledActivationCannotPublishDestination() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }

        let transport = SuspendingTransitionDriveUploadTransport()
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: try Self.makeMetadataStore(
                suiteName: suiteName
            ),
            uploadTransport: transport
        )
        let activation = Task {
            try await client.activateAccount(
                "google-user-cancelled",
                folders: DriveFolderConnection(
                    rootID: "root-cancelled",
                    dailyID: "daily-cancelled",
                    name: "Cancelled Archive"
                )
            )
        }
        await transport.waitUntilTransitionStarts()
        activation.cancel()
        await transport.releaseTransition()

        do {
            _ = try await activation.value
            XCTFail("Expected activation cancellation")
        } catch is CancellationError {
            // Cancellation won before the destination could be published.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-cancelled",
                kind: "manifest",
                date: nil,
                data: Data("{}".utf8)
            )
            XCTFail("Expected the cancelled destination to remain inactive")
        } catch DriveAPIError.accountNotReady {
            // The activation did not commit.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testMultipartUpsertUsesStableInjectedUploadOperation()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": "manifest-a",
                "name": "manifest.json",
            ]
        )
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        for _ in 0..<2 {
            _ = try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{\"schemaVersion\":1}".utf8)
            )
        }

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].request.httpMethod, "PATCH")
        XCTAssertEqual(
            invocations[0].request.url?.path,
            "/upload/drive/v3/files/manifest-a"
        )
        XCTAssertEqual(
            invocations[0].request.value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer test-token"
        )
        XCTAssertNil(invocations[0].request.httpBody)
        XCTAssertTrue(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains("{\"schemaVersion\":1}")
        )
        XCTAssertEqual(invocations[0].operationID.count, 64)
        XCTAssertEqual(
            invocations[0].operationID,
            invocations[1].operationID
        )
        XCTAssertEqual(
            invocations[0].destinationScopeID,
            invocations[1].destinationScopeID
        )
        XCTAssertEqual(invocations[0].destinationScopeID.count, 64)
        XCTAssertFalse(
            invocations[0].destinationScopeID.contains(accountID)
        )
        XCTAssertFalse(
            invocations[0].destinationScopeID.contains("root-a")
        )
        let destinationTransitions =
            await uploadTransport.recordedDestinationTransitions()
        XCTAssertEqual(destinationTransitions.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(destinationTransitions[0]),
            invocations[0].destinationScopeID
        )
    }

    @MainActor
    func testInvalidCachedArtifactIsRediscoveredBeforeUpload() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-invalid-cache"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }
        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "moved-manifest",
            for: "manifest",
            accountID: accountID
        )
        URLProtocolStub.setHandler { request in
            if request.url?.path == "/drive/v3/files/moved-manifest" {
                return try Self.response(
                    for: request,
                    json: [
                        "id": "moved-manifest",
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": ["root-a", "shared-parent"],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            }
            return try Self.response(
                for: request,
                json: [
                    "files": [
                        [
                            "id": "trashed-manifest",
                            "mimeType": "application/json",
                            "trashed": true,
                            "parents": ["root-a"],
                            "appProperties": [
                                "healthMuleKind": "manifest"
                            ],
                        ],
                        [
                            "id": "wrong-tag-manifest",
                            "mimeType": "application/json",
                            "trashed": false,
                            "parents": ["root-a"],
                            "appProperties": [
                                "healthMuleKind": "daily"
                            ],
                        ],
                        [
                            "id": "current-manifest",
                            "mimeType": "application/json",
                            "trashed": false,
                            "parents": ["root-a"],
                            "appProperties": [
                                "healthMuleKind": "manifest"
                            ],
                        ],
                    ]
                ]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": "current-manifest",
                "name": "manifest.json",
            ]
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        _ = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(
            invocations[0].request.url?.lastPathComponent,
            "current-manifest"
        )
        let cachedID = await metadataStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(cachedID, "current-manifest")
    }

    @MainActor
    func testCachedCreateReservationSurvivesTransientValidation404()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-pending-create"
        let reservedID = "reserved-manifest-id"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }
        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.reserveFileID(
            reservedID,
            for: "manifest",
            accountID: accountID
        )
        let metadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(metadataRequests.next(), 0)
            XCTAssertEqual(
                request.url?.path,
                "/drive/v3/files/\(reservedID)"
            )
            return try Self.response(
                for: request,
                status: 404,
                json: ["error": ["errors": []]]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": reservedID,
                "name": "manifest.json",
            ],
            responseStatuses: [409, 200]
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let item = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{\"revision\":2}".utf8)
        )

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(item.id, reservedID)
        XCTAssertEqual(metadataRequests.count, 1)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].request.httpMethod, "POST")
        XCTAssertEqual(
            invocations[0].request.url?.path,
            "/upload/drive/v3/files"
        )
        XCTAssertTrue(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains(#""id":"reserved-manifest-id""#)
        )
        XCTAssertEqual(invocations[1].request.httpMethod, "PATCH")
        XCTAssertEqual(
            invocations[1].request.url?.path,
            "/upload/drive/v3/files/\(reservedID)"
        )
        let cachedSnapshot = await metadataStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(cachedSnapshot.fileID, reservedID)
        XCTAssertEqual(cachedSnapshot.status, .committed)
    }

    @MainActor
    func testAmbiguousPendingCreateRemainsReservedWithoutGeneratingAnotherID()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-ambiguous-pending-create"
        let reservedID = "ambiguous-reserved-manifest-id"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }
        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.reserveFileID(
            reservedID,
            for: "manifest",
            accountID: accountID
        )
        let metadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(metadataRequests.next(), 0)
            XCTAssertEqual(
                request.url?.path,
                "/drive/v3/files/\(reservedID)"
            )
            return try Self.response(
                for: request,
                status: 404,
                json: ["error": ["errors": []]]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": reservedID,
                "name": "manifest.json",
            ],
            responseStatuses: [409, 404]
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        do {
            _ = try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{\"revision\":2}".utf8)
            )
            XCTFail("Expected the ambiguous create to remain retryable")
        } catch let error as DriveAPIError {
            guard case .accountNotReady = error else {
                return XCTFail("Expected accountNotReady, got \(error)")
            }
            XCTAssertTrue(error.isRetryable)
        }

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(metadataRequests.count, 1)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].request.httpMethod, "POST")
        XCTAssertTrue(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains(#""id":"ambiguous-reserved-manifest-id""#)
        )
        XCTAssertEqual(invocations[1].request.httpMethod, "PATCH")
        XCTAssertEqual(
            invocations[1].request.url?.lastPathComponent,
            reservedID
        )
        let cachedSnapshot = await metadataStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(cachedSnapshot.fileID, reservedID)
        XCTAssertEqual(cachedSnapshot.status, .pendingCreate)
    }

    @MainActor
    func testAmbiguousCreateReservationSurvivesRelaunchAndCommitsAfterRetry()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-ambiguous-create-relaunch"
        let reservedID = "relaunch-reserved-manifest-id"
        let folders = DriveFolderConnection(
            rootID: "root-a",
            dailyID: "daily-a",
            name: "Archive A"
        )
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let firstMetadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            switch firstMetadataRequests.next() {
            case 0:
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 1:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": [reservedID]]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }
        let firstTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": reservedID,
                "name": "manifest.json",
            ],
            responseStatuses: [409, 404]
        )

        do {
            let firstStore = try Self.makeMetadataStore(
                suiteName: suiteName
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLProtocolStub.self]
            let firstClient = DriveAPIClient(
                tokenProvider: { _ in "test-token" },
                metadataStore: firstStore,
                session: URLSession(configuration: configuration),
                uploadTransport: firstTransport
            )
            try await firstClient.activateAccount(
                accountID,
                folders: folders
            )

            do {
                _ = try await firstClient.upsertJSON(
                    named: "manifest.json",
                    parentID: folders.rootID,
                    kind: "manifest",
                    date: nil,
                    data: Data("{\"revision\":2}".utf8)
                )
                XCTFail("Expected the ambiguous create to remain retryable")
            } catch let error as DriveAPIError {
                guard case .accountNotReady = error else {
                    return XCTFail("Expected accountNotReady, got \(error)")
                }
                XCTAssertTrue(error.isRetryable)
            }

            let pendingSnapshot = await firstStore.fileIDSnapshot(
                for: "manifest",
                accountID: accountID
            )
            XCTAssertEqual(pendingSnapshot.fileID, reservedID)
            XCTAssertEqual(pendingSnapshot.status, .pendingCreate)
        }

        let firstInvocations = await firstTransport.recordedInvocations()
        XCTAssertEqual(firstMetadataRequests.count, 2)
        XCTAssertEqual(firstInvocations.count, 2)
        XCTAssertEqual(firstInvocations[0].request.httpMethod, "POST")
        XCTAssertTrue(
            String(decoding: firstInvocations[0].body, as: UTF8.self)
                .contains(#""id":"relaunch-reserved-manifest-id""#)
        )
        XCTAssertEqual(firstInvocations[1].request.httpMethod, "PATCH")
        XCTAssertEqual(
            firstInvocations[1].request.url?.lastPathComponent,
            reservedID
        )

        let retryMetadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(retryMetadataRequests.next(), 0)
            XCTAssertEqual(
                request.url?.path,
                "/drive/v3/files/\(reservedID)"
            )
            return try Self.response(
                for: request,
                status: 404,
                json: ["error": ["errors": []]]
            )
        }
        let retryTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": reservedID,
                "name": "manifest.json",
            ],
            responseStatuses: [409, 200]
        )

        do {
            let retryStore = try Self.makeMetadataStore(
                suiteName: suiteName
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLProtocolStub.self]
            let retryClient = DriveAPIClient(
                tokenProvider: { _ in "test-token" },
                metadataStore: retryStore,
                session: URLSession(configuration: configuration),
                uploadTransport: retryTransport
            )
            try await retryClient.activateAccount(
                accountID,
                folders: folders
            )

            let item = try await retryClient.upsertJSON(
                named: "manifest.json",
                parentID: folders.rootID,
                kind: "manifest",
                date: nil,
                data: Data("{\"revision\":3}".utf8)
            )
            XCTAssertEqual(item.id, reservedID)
        }

        let retryInvocations = await retryTransport.recordedInvocations()
        XCTAssertEqual(retryMetadataRequests.count, 1)
        XCTAssertEqual(retryInvocations.count, 2)
        XCTAssertEqual(retryInvocations[0].request.httpMethod, "POST")
        XCTAssertTrue(
            String(decoding: retryInvocations[0].body, as: UTF8.self)
                .contains(#""id":"relaunch-reserved-manifest-id""#)
        )
        XCTAssertEqual(retryInvocations[1].request.httpMethod, "PATCH")
        XCTAssertEqual(
            retryInvocations[1].request.url?.lastPathComponent,
            reservedID
        )

        let finalStore = try Self.makeMetadataStore(suiteName: suiteName)
        let committedSnapshot = await finalStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(committedSnapshot.fileID, reservedID)
        XCTAssertEqual(committedSnapshot.status, .committed)
    }

    @MainActor
    func testCommittedHardDeletedFileGetsFreshGeneratedID() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-hard-deleted-committed"
        let staleID = "committed-deleted-manifest-id"
        let freshID = "fresh-generated-manifest-id"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }
        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            staleID,
            for: "manifest",
            accountID: accountID
        )
        let metadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            switch metadataRequests.next() {
            case 0:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/\(staleID)"
                )
                return try Self.response(
                    for: request,
                    status: 404,
                    json: ["error": ["errors": []]]
                )
            case 1:
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 2:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": [freshID]]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": freshID,
                "name": "manifest.json",
            ]
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let item = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(item.id, freshID)
        XCTAssertEqual(metadataRequests.count, 3)
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].request.httpMethod, "POST")
        XCTAssertTrue(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains(#""id":"fresh-generated-manifest-id""#)
        )
        XCTAssertFalse(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains(#""id":"committed-deleted-manifest-id""#)
        )
        let cachedSnapshot = await metadataStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(cachedSnapshot.fileID, freshID)
        XCTAssertEqual(cachedSnapshot.status, .committed)
    }

    @MainActor
    func testVerifiedCommittedFileDeletedBeforePatchGetsFreshID()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-delete-race"
        let staleID = "verified-then-deleted-manifest-id"
        let freshID = "fresh-id-after-delete-race"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }
        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            staleID,
            for: "manifest",
            accountID: accountID
        )
        let metadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            switch metadataRequests.next() {
            case 0:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/\(staleID)"
                )
                return try Self.response(
                    for: request,
                    json: [
                        "id": staleID,
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": ["root-a"],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            case 1:
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 2:
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": [freshID]]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": freshID,
                "name": "manifest.json",
            ],
            responseStatuses: [404, 200]
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let item = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(item.id, freshID)
        XCTAssertEqual(metadataRequests.count, 3)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].request.httpMethod, "PATCH")
        XCTAssertEqual(
            invocations[0].request.url?.lastPathComponent,
            staleID
        )
        XCTAssertEqual(invocations[1].request.httpMethod, "POST")
        XCTAssertTrue(
            String(decoding: invocations[1].body, as: UTF8.self)
                .contains(#""id":"fresh-id-after-delete-race""#)
        )
        let cachedSnapshot = await metadataStore.fileIDSnapshot(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(cachedSnapshot.fileID, freshID)
        XCTAssertEqual(cachedSnapshot.status, .committed)
    }

    @MainActor
    func testConcurrentUncachedUpsertsUseOneIDThenCreateAndUpdateInOrder()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-concurrent-upserts"
        let metadataWriteGate = AsyncSuspensionGate()
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(
            suiteName: suiteName,
            successfulConditionalWriteBarrier: {
                await metadataWriteGate.suspend()
            }
        )
        let metadataRequests = RequestCounter()
        URLProtocolStub.setHandler { request in
            switch metadataRequests.next() {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                return try Self.response(
                    for: request,
                    json: ["files": []]
                )
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generateIds"
                )
                return try Self.response(
                    for: request,
                    json: ["ids": ["generated-manifest-id"]]
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/generated-manifest-id"
                )
                return try Self.response(
                    for: request,
                    json: [
                        "id": "generated-manifest-id",
                        "name": "manifest.json",
                        "mimeType": "application/json",
                        "trashed": false,
                        "parents": ["root-a"],
                        "appProperties": [
                            "healthMuleKind": "manifest"
                        ],
                    ]
                )
            default:
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
        }
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": "generated-manifest-id",
                "name": "manifest.json",
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: URLSession(configuration: configuration),
            uploadTransport: uploadTransport
        )
        let folders = DriveFolderConnection(
            rootID: "root-a",
            dailyID: "daily-a",
            name: "Archive A"
        )
        try await client.activateAccount(accountID, folders: folders)
        let destinationScopeID = DriveMetadataStore.destinationNamespace(
            for: accountID,
            rootID: folders.rootID,
            dailyID: folders.dailyID
        )

        let first = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: folders.rootID,
                kind: "manifest",
                date: nil,
                data: Data("{\"version\":1}".utf8)
            )
        }
        await metadataWriteGate.waitUntilSuspended()
        let second = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: folders.rootID,
                kind: "manifest",
                date: nil,
                data: Data("{\"version\":2}".utf8)
            )
        }
        let bothUpsertsReserved =
            try await waitForPendingUpsertCount(
                2,
                accountID: accountID,
                destinationScopeID: destinationScopeID,
                cacheKey: "manifest",
                client: client
            )
        XCTAssertTrue(bothUpsertsReserved)
        XCTAssertEqual(metadataRequests.count, 2)
        let invocationsBeforeRelease =
            await uploadTransport.recordedInvocations()
        XCTAssertTrue(invocationsBeforeRelease.isEmpty)

        await metadataWriteGate.release()
        let firstItem = try await first.value
        let secondItem = try await second.value
        let invocations = await uploadTransport.recordedInvocations()

        XCTAssertEqual(firstItem.id, "generated-manifest-id")
        XCTAssertEqual(secondItem.id, "generated-manifest-id")
        XCTAssertEqual(metadataRequests.count, 3)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].request.httpMethod, "POST")
        XCTAssertEqual(
            invocations[0].request.url?.path,
            "/upload/drive/v3/files"
        )
        XCTAssertTrue(
            String(decoding: invocations[0].body, as: UTF8.self)
                .contains("{\"version\":1}")
        )
        XCTAssertEqual(invocations[1].request.httpMethod, "PATCH")
        XCTAssertEqual(
            invocations[1].request.url?.path,
            "/upload/drive/v3/files/generated-manifest-id"
        )
        XCTAssertTrue(
            String(decoding: invocations[1].body, as: UTF8.self)
                .contains("{\"version\":2}")
        )
        let storedFileID = await metadataStore.fileID(
            for: "manifest",
            accountID: accountID
        )
        XCTAssertEqual(storedFileID, "generated-manifest-id")
    }

    @MainActor
    func testCancellingQueuedUpsertReturnsPromptlyAndNeverUploads()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-cancelled-upsert"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let uploadTransport = SuspendingDriveUploadTransport()
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        let folders = DriveFolderConnection(
            rootID: "root-a",
            dailyID: "daily-a",
            name: "Archive A"
        )
        try await client.activateAccount(accountID, folders: folders)
        let destinationScopeID = DriveMetadataStore.destinationNamespace(
            for: accountID,
            rootID: folders.rootID,
            dailyID: folders.dailyID
        )

        let first = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: folders.rootID,
                kind: "manifest",
                date: nil,
                data: Data("{\"version\":1}".utf8)
            )
        }
        await uploadTransport.waitUntilUploadStarts()
        let second = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: folders.rootID,
                kind: "manifest",
                date: nil,
                data: Data("{\"version\":2}".utf8)
            )
        }
        let bothReserved = try await waitForPendingUpsertCount(
            2,
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            cacheKey: "manifest",
            client: client
        )
        XCTAssertTrue(bothReserved)

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected the queued upsert to cancel promptly")
        } catch is CancellationError {
            // Its reserved worker remains queued only long enough to unwind.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let uploadCountAfterCancellation =
            await uploadTransport.recordedUploadCount()
        XCTAssertEqual(uploadCountAfterCancellation, 1)

        await uploadTransport.releaseUpload()
        _ = try await first.value
        let drained = try await waitForPendingUpsertCount(
            0,
            accountID: accountID,
            destinationScopeID: destinationScopeID,
            cacheKey: "manifest",
            client: client
        )
        XCTAssertTrue(drained)
        let finalUploadCount = await uploadTransport.recordedUploadCount()
        XCTAssertEqual(finalUploadCount, 1)
    }

    @MainActor
    func testSuspendedUploadCannotCommitAfterDestinationTransition()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let firstAccountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: firstAccountID
        )
        let uploadTransport = SuspendingDriveUploadTransport()
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            firstAccountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let staleUpsert = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{\"schemaVersion\":1}".utf8)
            )
        }
        await uploadTransport.waitUntilUploadStarts()
        try await client.activateAccount(
            "google-user-b",
            folders: DriveFolderConnection(
                rootID: "root-b",
                dailyID: "daily-b",
                name: "Archive B"
            )
        )
        await uploadTransport.releaseUpload()

        do {
            _ = try await staleUpsert.value
            XCTFail("Expected the old destination upload to be invalidated")
        } catch DriveAPIError.accountNotReady {
            // The new activation won the race.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let firstAccountManifestID = await metadataStore.fileID(
            for: "manifest",
            accountID: firstAccountID
        )
        XCTAssertEqual(firstAccountManifestID, "manifest-a")
    }

    @MainActor
    func testConditionalMetadataWriteCannotReturnStaleSuccess()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let firstAccountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataWriteGate = AsyncSuspensionGate()
        let metadataStore = try Self.makeMetadataStore(
            suiteName: suiteName,
            successfulConditionalWriteBarrier: {
                await metadataWriteGate.suspend()
            }
        )
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: firstAccountID
        )
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": "stale-response-id",
                "name": "manifest.json",
            ]
        )
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            firstAccountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let staleUpsert = Task {
            try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{\"schemaVersion\":1}".utf8)
            )
        }
        await metadataWriteGate.waitUntilSuspended()
        try await client.activateAccount(
            "google-user-b",
            folders: DriveFolderConnection(
                rootID: "root-b",
                dailyID: "daily-b",
                name: "Archive B"
            )
        )
        await metadataWriteGate.release()

        do {
            _ = try await staleUpsert.value
            XCTFail("Expected the stale metadata completion to be rejected")
        } catch DriveAPIError.accountNotReady {
            // The post-write activation check rejected the stale success.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackgroundUploadConfigurationSurvivesProcessSuspension() {
        let configuration = BackgroundDriveUploadTransport.makeConfiguration()

        XCTAssertEqual(
            configuration.identifier,
            BackgroundDriveUploadTransport.sessionIdentifier
        )
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(
            BackgroundDriveUploadTransport.defaultResponseWaitTimeout,
            .seconds(15)
        )
        XCTAssertEqual(
            BackgroundDriveUploadTransport.defaultTransitionDrainTimeout,
            .seconds(15)
        )
    }

    @MainActor
    func testBackgroundDelegateRetainsCompletionForLateObservers()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDelegateLateObserverTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let expiryScheduler = ManualExpiryScheduler()
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            completedResponseLimit: 4,
            completedResponseGracePeriod: .seconds(60),
            cacheExpiryScheduler: { _, action in
                expiryScheduler.schedule(action)
            }
        )
        let taskIdentifier = 41
        let expected = try Self.makeDriveUploadResponse(
            body: "completed-with-waiter"
        )
        let earlyObserver = Task {
            try await delegate.responseForTesting(
                taskIdentifier: taskIdentifier
            )
        }
        let registered = try await waitForDelegateResponseWaiter(
            taskIdentifier: taskIdentifier,
            expectedCount: 1,
            delegate: delegate
        )
        XCTAssertTrue(registered)

        delegate.completeResponseForTesting(
            taskIdentifier: taskIdentifier,
            result: .success(expected)
        )
        let earlyResponse = try await earlyObserver.value
        let firstLateResponse = try await delegate.responseForTesting(
            taskIdentifier: taskIdentifier
        )
        let secondLateResponse = try await delegate.responseForTesting(
            taskIdentifier: taskIdentifier
        )

        XCTAssertEqual(earlyResponse.data, expected.data)
        XCTAssertEqual(firstLateResponse.data, expected.data)
        XCTAssertEqual(secondLateResponse.data, expected.data)
        XCTAssertEqual(delegate.completedResponseCountForTesting(), 1)
        XCTAssertEqual(expiryScheduler.scheduledCount, 1)
    }

    func testBackgroundDelegateCacheIsBoundedAndExpiryIsGenerationSafe()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDelegateCacheBoundsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let expiryScheduler = ManualExpiryScheduler()
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            completedResponseLimit: 2,
            completedResponseGracePeriod: .seconds(60),
            cacheExpiryScheduler: { _, action in
                expiryScheduler.schedule(action)
            }
        )

        for taskIdentifier in 1...3 {
            delegate.completeResponseForTesting(
                taskIdentifier: taskIdentifier,
                result: .success(
                    try Self.makeDriveUploadResponse(
                        body: "response-\(taskIdentifier)"
                    )
                )
            )
        }
        XCTAssertEqual(delegate.completedResponseCountForTesting(), 2)
        XCTAssertFalse(
            delegate.hasCompletedResponseForTesting(taskIdentifier: 1)
        )
        XCTAssertTrue(
            delegate.hasCompletedResponseForTesting(taskIdentifier: 2)
        )
        XCTAssertTrue(
            delegate.hasCompletedResponseForTesting(taskIdentifier: 3)
        )

        delegate.completeResponseForTesting(
            taskIdentifier: 3,
            result: .success(
                try Self.makeDriveUploadResponse(body: "replacement")
            )
        )
        expiryScheduler.runScheduledAction(at: 2)
        XCTAssertTrue(
            delegate.hasCompletedResponseForTesting(taskIdentifier: 3)
        )
        expiryScheduler.runScheduledAction(at: 3)
        XCTAssertFalse(
            delegate.hasCompletedResponseForTesting(taskIdentifier: 3)
        )
        XCTAssertEqual(delegate.completedResponseCountForTesting(), 1)
    }

    @MainActor
    func testCancelledFinishedEventWaiterPreservesNextEvent()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundFinishedEventCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root)
        )
        let waiter = Task {
            try await delegate.waitForFinishedEvents()
        }
        let registered = try await waitForDelegateEventWaiter(
            expectedCount: 1,
            delegate: delegate
        )
        XCTAssertTrue(registered)

        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Expected finished-event waiter cancellation")
        } catch is CancellationError {
            // Cancellation won the gate before a finish event arrived.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        delegate.completeFinishedEventsForTesting()
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 1)
        try await delegate.waitForFinishedEvents()
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 0)
    }

    @MainActor
    func testFinishedEventWinningGateIsNotLostToLateCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundFinishedEventWinnerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root)
        )
        let waiter = Task {
            try await delegate.waitForFinishedEvents()
        }
        let registered = try await waitForDelegateEventWaiter(
            expectedCount: 1,
            delegate: delegate
        )
        XCTAssertTrue(registered)

        delegate.completeFinishedEventsForTesting()
        waiter.cancel()

        try await waiter.value
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 0)
    }

    @MainActor
    func testEachFinishedEventCompletesOnlyOneRegisteredWaiter()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundFinishedEventCreditTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root)
        )
        let firstWaiter = Task {
            try await delegate.waitForFinishedEvents()
        }
        let secondWaiter = Task {
            try await delegate.waitForFinishedEvents()
        }
        let registered = try await waitForDelegateEventWaiter(
            expectedCount: 2,
            delegate: delegate
        )
        XCTAssertTrue(registered)

        delegate.completeFinishedEventsForTesting()

        XCTAssertEqual(delegate.eventWaiterCountForTesting(), 1)
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 0)

        delegate.completeFinishedEventsForTesting()
        try await firstWaiter.value
        try await secondWaiter.value
        XCTAssertEqual(delegate.eventWaiterCountForTesting(), 0)
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 0)
    }

    @MainActor
    func testCancellationDuringFinishedEventRegistrationPreservesSignal()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundFinishedEventRegistrationRaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = BackgroundDriveUploadSessionDelegate(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root)
        )
        let registrationReached = DispatchSemaphore(value: 0)
        let releaseRegistration = DispatchSemaphore(value: 0)
        let waiter = Task.detached {
            try await delegate.waitForFinishedEventsForTesting {
                registrationReached.signal()
                releaseRegistration.wait()
            }
        }
        XCTAssertEqual(
            registrationReached.wait(timeout: .now() + 2),
            .success
        )

        waiter.cancel()
        delegate.completeFinishedEventsForTesting()
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 1)
        releaseRegistration.signal()

        do {
            try await waiter.value
            XCTFail("Expected registration-race waiter cancellation")
        } catch is CancellationError {
            // The canceled gate cannot consume the pending event.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 1)
        try await delegate.waitForFinishedEvents()
        XCTAssertEqual(delegate.unclaimedFinishedEventCountForTesting(), 0)
    }

    @MainActor
    func testBackgroundUploadTimeoutLeavesSystemTransferRunning()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveUploadTimeoutTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "upload started")
        let requestReleased = expectation(description: "upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .zero
        )
        let destinationScopeID = String(repeating: "b", count: 64)
        try await transport.transition(
            toDestinationScopeID: destinationScopeID
        )
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/manifest-a"
                )
            )
        )
        request.httpMethod = "PATCH"
        request.setValue(
            "Bearer test-token",
            forHTTPHeaderField: "Authorization"
        )
        let upload = Task {
            try await transport.upload(
                request: request,
                body: Data("multipart body".utf8),
                operationID: String(repeating: "a", count: 64),
                destinationScopeID: destinationScopeID
            )
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        do {
            _ = try await upload.value
            XCTFail("Expected the in-process observation window to expire")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        XCTAssertEqual(BackgroundUploadURLProtocol.stopLoadingCount, 0)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            stagedFiles.filter { $0.pathExtension == "upload" }.count,
            1
        )
        try await transport.transition(
            toDestinationScopeID: destinationScopeID
        )
        XCTAssertEqual(BackgroundUploadURLProtocol.stopLoadingCount, 0)

        releaseResponse.signal()
        await fulfillment(of: [requestReleased], timeout: 2)
    }

    @MainActor
    func testBackgroundDestinationTransitionDrainsStaleScopeBeforePreparing()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveScopeTransitionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "old upload started")
        let requestReleased = expectation(description: "old upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .zero,
            transitionDrainTimeout: .milliseconds(200)
        )
        let oldScopeID = String(repeating: "a", count: 64)
        let newScopeID = String(repeating: "b", count: 64)
        try await transport.transition(toDestinationScopeID: oldScopeID)
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/manifest-a"
                )
            )
        )
        request.httpMethod = "PATCH"
        let upload = Task {
            try await transport.upload(
                request: request,
                body: Data("multipart body".utf8),
                operationID: String(repeating: "c", count: 64),
                destinationScopeID: oldScopeID
            )
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        do {
            _ = try await upload.value
            XCTFail("Expected the observation window to expire")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        do {
            try await transport.transition(toDestinationScopeID: newScopeID)
            XCTFail("Expected an ambiguous stale transfer to fail closed")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(BackgroundUploadURLProtocol.stopLoadingCount, 0)
        do {
            _ = try await transport.upload(
                request: request,
                body: Data("new multipart body".utf8),
                operationID: String(repeating: "d", count: 64),
                destinationScopeID: newScopeID
            )
            XCTFail("Expected the new destination to remain unprepared")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let transitionFinished = CompletionFlag()
        let transition = Task {
            defer { transitionFinished.markFinished() }
            try await transport.transition(
                toDestinationScopeID: newScopeID
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(transitionFinished.isFinished)
        XCTAssertEqual(BackgroundUploadURLProtocol.stopLoadingCount, 0)
        releaseResponse.signal()
        await fulfillment(of: [requestReleased], timeout: 2)
        try await transition.value
        XCTAssertTrue(transitionFinished.isFinished)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            remainingFiles.filter { $0.pathExtension == "upload" }.isEmpty
        )
    }

    @MainActor
    func testBackgroundDestinationTransitionDrainsTerminalTimedOutFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveTerminalFailureDrainTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "old upload started")
        let requestReleased = expectation(description: "old upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse,
            completionErrorCode: .timedOut
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .zero,
            transitionDrainTimeout: .seconds(2)
        )
        let oldScopeID = String(repeating: "a", count: 64)
        let newScopeID = String(repeating: "b", count: 64)
        try await transport.transition(toDestinationScopeID: oldScopeID)
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/manifest-a"
                )
            )
        )
        request.httpMethod = "PATCH"
        let upload = Task {
            try await transport.upload(
                request: request,
                body: Data("multipart body".utf8),
                operationID: String(repeating: "c", count: 64),
                destinationScopeID: oldScopeID
            )
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        do {
            _ = try await upload.value
            XCTFail("Expected the in-process observation window to expire")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        let transition = Task {
            try await transport.transition(toDestinationScopeID: newScopeID)
        }
        let observingTerminalTask = try await
            waitForBackgroundResponseWaiter(
                expectedCount: 1,
                transport: transport
            )
        XCTAssertTrue(observingTerminalTask)
        releaseResponse.signal()
        await fulfillment(of: [requestReleased], timeout: 2)
        try await transition.value
    }

    @MainActor
    func testCancellingStaleScopeDrainPropagatesCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveDrainCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "old upload started")
        let requestReleased = expectation(description: "old upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .zero,
            transitionDrainTimeout: .seconds(5)
        )
        let oldScopeID = String(repeating: "a", count: 64)
        let newScopeID = String(repeating: "b", count: 64)
        try await transport.transition(toDestinationScopeID: oldScopeID)
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/manifest-a"
                )
            )
        )
        request.httpMethod = "PATCH"
        let upload = Task {
            try await transport.upload(
                request: request,
                body: Data("multipart body".utf8),
                operationID: String(repeating: "c", count: 64),
                destinationScopeID: oldScopeID
            )
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        do {
            _ = try await upload.value
            XCTFail("Expected the in-process observation window to expire")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        let transition = Task {
            try await transport.transition(toDestinationScopeID: newScopeID)
        }
        let observingStaleTask = try await waitForBackgroundResponseWaiter(
            expectedCount: 1,
            transport: transport
        )
        XCTAssertTrue(observingStaleTask)
        transition.cancel()
        do {
            try await transition.value
            XCTFail("Expected stale-scope drain cancellation")
        } catch is CancellationError {
            // Caller cancellation must not be mistaken for task completion.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        releaseResponse.signal()
        await fulfillment(of: [requestReleased], timeout: 2)
    }

    @MainActor
    func testDestinationTransitionInvalidatesInProcessUploadAsURLCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveTransitionCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "old upload started")
        let requestReleased = expectation(description: "old upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .seconds(5),
            transitionDrainTimeout: .seconds(5)
        )
        let oldScopeID = String(repeating: "a", count: 64)
        let newScopeID = String(repeating: "b", count: 64)
        try await transport.transition(toDestinationScopeID: oldScopeID)
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/manifest-a"
                )
            )
        )
        request.httpMethod = "PATCH"
        let upload = Task {
            try await transport.upload(
                request: request,
                body: Data("multipart body".utf8),
                operationID: String(repeating: "c", count: 64),
                destinationScopeID: oldScopeID
            )
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        let transitionFinished = CompletionFlag()
        let transition = Task {
            defer { transitionFinished.markFinished() }
            try await transport.transition(
                toDestinationScopeID: newScopeID
            )
        }

        do {
            _ = try await upload.value
            XCTFail("Expected transition invalidation")
        } catch is CancellationError {
            XCTFail("Internal invalidation leaked as caller cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(transitionFinished.isFinished)
        XCTAssertEqual(BackgroundUploadURLProtocol.stopLoadingCount, 0)

        releaseResponse.signal()
        await fulfillment(of: [requestReleased], timeout: 2)
        try await transition.value
        XCTAssertTrue(transitionFinished.isFinished)
        // URLProtocol may receive stopLoading after normal completion as
        // teardown; the pre-release assertion above is the cancellation proof.
    }

    @MainActor
    func testCancellingOneJoinedBackgroundCallerKeepsSharedUploadRunning()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveCoalescingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "upload started")
        let requestReleased = expectation(description: "upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .seconds(5)
        )
        let destinationScopeID = String(repeating: "a", count: 64)
        let operationID = String(repeating: "b", count: 64)
        try await transport.transition(
            toDestinationScopeID: destinationScopeID
        )
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/coalesced"
                )
            )
        )
        request.httpMethod = "PATCH"

        let first = Task {
            try await transport.upload(
                request: request,
                body: Data("same multipart body".utf8),
                operationID: operationID,
                destinationScopeID: destinationScopeID
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        let second = Task {
            try await transport.upload(
                request: request,
                body: Data("same multipart body".utf8),
                operationID: operationID,
                destinationScopeID: destinationScopeID
            )
        }

        let joined = try await waitForReservedCallerCount(
            2,
            operationID: operationID,
            destinationScopeID: destinationScopeID,
            transport: transport
        )
        XCTAssertTrue(joined)
        XCTAssertEqual(BackgroundUploadURLProtocol.startLoadingCount, 1)

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected the joined caller to cancel promptly")
        } catch is CancellationError {
            // The first caller still owns the shared transfer.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let remainingCaller = try await waitForReservedCallerCount(
            1,
            operationID: operationID,
            destinationScopeID: destinationScopeID,
            transport: transport
        )
        XCTAssertTrue(remainingCaller)
        XCTAssertEqual(BackgroundUploadURLProtocol.startLoadingCount, 1)

        releaseResponse.signal()
        let firstResponse = try await first.value
        await fulfillment(of: [requestReleased], timeout: 2)

        XCTAssertFalse(firstResponse.data.isEmpty)
        XCTAssertEqual(BackgroundUploadURLProtocol.startLoadingCount, 1)
    }

    @MainActor
    func testCancellingUniqueQueuedBackgroundUploadPreventsItStarting()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveQueuedCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "first upload started")
        let requestReleased = expectation(description: "first upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .seconds(5)
        )
        let destinationScopeID = String(repeating: "c", count: 64)
        let firstOperationID = String(repeating: "d", count: 64)
        let secondOperationID = String(repeating: "e", count: 64)
        try await transport.transition(
            toDestinationScopeID: destinationScopeID
        )
        var firstRequest = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/first"
                )
            )
        )
        firstRequest.httpMethod = "PATCH"
        var secondRequest = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/second"
                )
            )
        )
        secondRequest.httpMethod = "PATCH"

        let first = Task {
            try await transport.upload(
                request: firstRequest,
                body: Data("first multipart body".utf8),
                operationID: firstOperationID,
                destinationScopeID: destinationScopeID
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        let second = Task {
            try await transport.upload(
                request: secondRequest,
                body: Data("second multipart body".utf8),
                operationID: secondOperationID,
                destinationScopeID: destinationScopeID
            )
        }
        let secondReserved = try await waitForReservedCallerCount(
            1,
            operationID: secondOperationID,
            destinationScopeID: destinationScopeID,
            transport: transport
        )
        XCTAssertTrue(secondReserved)

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected queued upload cancellation")
        } catch is CancellationError {
            // Its worker is cancelled before it may start a URLSession task.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            BackgroundUploadURLProtocol.startedRequestPaths,
            ["/upload/drive/v3/files/first"]
        )

        releaseResponse.signal()
        _ = try await first.value
        await fulfillment(of: [requestReleased], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            BackgroundUploadURLProtocol.startedRequestPaths,
            ["/upload/drive/v3/files/first"]
        )
    }

    @MainActor
    func testConcurrentDifferentBackgroundUploadsRunInReservationOrder()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveOrderingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let requestStarted = expectation(description: "first upload started")
        let requestReleased = expectation(description: "first upload released")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            releaseResponse.signal()
            BackgroundUploadURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        BackgroundUploadURLProtocol.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundUploadURLProtocol.self]
        let transport = BackgroundDriveUploadTransport(
            bodyStore: BackgroundDriveUploadBodyStore(directoryURL: root),
            configuration: configuration,
            responseWaitTimeout: .seconds(5)
        )
        let destinationScopeID = String(repeating: "c", count: 64)
        let firstOperationID = String(repeating: "d", count: 64)
        let secondOperationID = String(repeating: "e", count: 64)
        try await transport.transition(
            toDestinationScopeID: destinationScopeID
        )
        var firstRequest = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/first"
                )
            )
        )
        firstRequest.httpMethod = "PATCH"
        var secondRequest = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://www.googleapis.com/upload/drive/v3/files/second"
                )
            )
        )
        secondRequest.httpMethod = "PATCH"

        let first = Task {
            try await transport.upload(
                request: firstRequest,
                body: Data("first multipart body".utf8),
                operationID: firstOperationID,
                destinationScopeID: destinationScopeID
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        let second = Task {
            try await transport.upload(
                request: secondRequest,
                body: Data("second multipart body".utf8),
                operationID: secondOperationID,
                destinationScopeID: destinationScopeID
            )
        }

        let secondReserved = try await waitForReservedCallerCount(
            1,
            operationID: secondOperationID,
            destinationScopeID: destinationScopeID,
            transport: transport
        )
        XCTAssertTrue(secondReserved)
        XCTAssertEqual(
            BackgroundUploadURLProtocol.startedRequestPaths,
            ["/upload/drive/v3/files/first"]
        )

        releaseResponse.signal()
        releaseResponse.signal()
        _ = try await first.value
        _ = try await second.value
        await fulfillment(of: [requestReleased], timeout: 2)

        XCTAssertEqual(
            BackgroundUploadURLProtocol.startedRequestPaths,
            [
                "/upload/drive/v3/files/first",
                "/upload/drive/v3/files/second",
            ]
        )
    }

    @MainActor
    func testDelayedBackgroundUpload401RefreshesTokenOnce() async throws {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let tokenRequests = RequestCounter()
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: [
                "id": "manifest-a",
                "name": "manifest.json",
            ],
            responseStatuses: [401, 200]
        )
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in
                switch tokenRequests.next() {
                case 0:
                    "validation-token"
                case 1:
                    "expired-in-background"
                default:
                    "refreshed-token"
                }
            },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        let item = try await client.upsertJSON(
            named: "manifest.json",
            parentID: "root-a",
            kind: "manifest",
            date: nil,
            data: Data("{}".utf8)
        )

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(item.id, "manifest-a")
        XCTAssertEqual(tokenRequests.count, 3)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(
            invocations.map {
                $0.request.value(forHTTPHeaderField: "Authorization")
            },
            [
                "Bearer expired-in-background",
                "Bearer refreshed-token",
            ]
        )
        XCTAssertNotEqual(
            invocations[0].operationID,
            invocations[1].operationID
        )
    }

    @MainActor
    func testRepeatedBackgroundUpload401RequiresReauthorization()
        async throws
    {
        let suiteName = "DriveAPIClientTests.\(UUID().uuidString)"
        let accountID = "google-user-a"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
            URLProtocolStub.removeHandler()
        }

        let metadataStore = try Self.makeMetadataStore(suiteName: suiteName)
        await metadataStore.setFileID(
            "manifest-a",
            for: "manifest",
            accountID: accountID
        )
        let tokenRequests = RequestCounter()
        let uploadTransport = try RecordingDriveUploadTransport(
            responseJSON: ["error": ["errors": []]],
            responseStatuses: [401, 401, 200]
        )
        let session = Self.cachedArtifactValidationSession(
            fileID: "manifest-a",
            parentID: "root-a"
        )
        let client = DriveAPIClient(
            tokenProvider: { _ in
                "token-\(tokenRequests.next())"
            },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: uploadTransport
        )
        try await client.activateAccount(
            accountID,
            folders: DriveFolderConnection(
                rootID: "root-a",
                dailyID: "daily-a",
                name: "Archive A"
            )
        )

        do {
            _ = try await client.upsertJSON(
                named: "manifest.json",
                parentID: "root-a",
                kind: "manifest",
                date: nil,
                data: Data("{}".utf8)
            )
            XCTFail("Expected reauthorization")
        } catch let error as DriveAPIError {
            guard case .reauthorizationRequired = error else {
                return XCTFail(
                    "Expected reauthorizationRequired, got \(error)"
                )
            }
        }

        let invocations = await uploadTransport.recordedInvocations()
        XCTAssertEqual(tokenRequests.count, 3)
        XCTAssertEqual(invocations.count, 2)
    }

    func testBackgroundUploadBodyStoreStagesPrunesAndRejectsUnsafeNames()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundDriveUploadBodyStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundDriveUploadBodyStore(directoryURL: root)
        let first = try store.stage(Data("first".utf8))
        let second = try store.stage(Data("second".utf8))

        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))

        store.prune(keeping: [first.lastPathComponent])

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        store.remove(fileName: "../outside.upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let operationID = String(repeating: "a", count: 64)
        let destinationScopeID = String(repeating: "b", count: 64)
        let descriptor = BackgroundDriveUploadTaskDescriptor(
            destinationScopeID: destinationScopeID,
            operationID: operationID,
            bodyFileName: first.lastPathComponent
        )
        XCTAssertEqual(
            BackgroundDriveUploadTaskDescriptor(encoded: descriptor.encoded),
            descriptor
        )
        XCTAssertNil(
            BackgroundDriveUploadTaskDescriptor(
                encoded:
                    "v2|\(destinationScopeID)|\(operationID)|../outside.upload"
            )
        )
        XCTAssertNil(
            BackgroundDriveUploadTaskDescriptor(
                encoded: "v1|\(operationID)|\(first.lastPathComponent)"
            )
        )
    }

    private nonisolated static func makeMetadataStore(
        suiteName: String,
        legacyData: Data? = nil,
        successfulConditionalWriteBarrier:
            (@Sendable () async -> Void)? = nil
    ) throws -> DriveMetadataStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        if let legacyData {
            defaults.set(legacyData, forKey: "drive.metadata.v1")
        }
        let directory = metadataDirectory(for: suiteName)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return DriveMetadataStore(
            directoryURL: directory,
            defaults: defaults,
            successfulConditionalWriteBarrier:
                successfulConditionalWriteBarrier
        )
    }

    private nonisolated static func metadataDirectory(for suiteName: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "healthmule-drive-metadata-\(suiteName)",
            isDirectory: true
        )
    }

    private nonisolated static func metadataFileURL(
        suiteName: String,
        accountID: String
    ) -> URL {
        metadataDirectory(for: suiteName).appendingPathComponent(
            "\(metadataStateKey(for: accountID)).json"
        )
    }

    @MainActor
    private func waitForReservedCallerCount(
        _ expectedCount: Int,
        operationID: String,
        destinationScopeID: String,
        transport: BackgroundDriveUploadTransport
    ) async throws -> Bool {
        for _ in 0..<400 {
            if
                await transport.reservedCallerCount(
                    operationID: operationID,
                    destinationScopeID: destinationScopeID
                ) == expectedCount
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForPendingUpsertCount(
        _ expectedCount: Int,
        accountID: String,
        destinationScopeID: String,
        cacheKey: String,
        client: DriveAPIClient
    ) async throws -> Bool {
        for _ in 0..<400 {
            if
                await client.pendingUpsertCount(
                    accountID: accountID,
                    destinationScopeID: destinationScopeID,
                    cacheKey: cacheKey
                ) == expectedCount
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForFolderReservationCallerCount(
        _ expectedCount: Int,
        accountID: String,
        client: DriveAPIClient
    ) async throws -> Bool {
        for _ in 0..<400 {
            if
                await client.folderReservationCallerCount(
                    for: accountID
                ) == expectedCount
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForDelegateResponseWaiter(
        taskIdentifier: Int,
        expectedCount: Int,
        delegate: BackgroundDriveUploadSessionDelegate
    ) async throws -> Bool {
        for _ in 0..<400 {
            if
                delegate.responseWaiterCountForTesting(
                    taskIdentifier: taskIdentifier
                ) == expectedCount
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForDelegateEventWaiter(
        expectedCount: Int,
        delegate: BackgroundDriveUploadSessionDelegate
    ) async throws -> Bool {
        for _ in 0..<400 {
            if delegate.eventWaiterCountForTesting() == expectedCount {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForBackgroundResponseWaiter(
        expectedCount: Int,
        transport: BackgroundDriveUploadTransport
    ) async throws -> Bool {
        for _ in 0..<400 {
            if
                await transport.responseWaiterCountForTesting()
                    == expectedCount
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private static func makeClient(
        metadataStore: DriveMetadataStore
    ) -> DriveAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return DriveAPIClient(
            tokenProvider: { _ in "test-token" },
            metadataStore: metadataStore,
            session: session,
            uploadTransport: TestSessionDriveUploadTransport(
                session: session
            )
        )
    }

    private nonisolated static func response(
        for request: URLRequest,
        status: Int = 200,
        json: Any
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            response,
            try JSONSerialization.data(withJSONObject: json)
        )
    }

    private nonisolated static func makeDriveUploadResponse(
        body: String
    ) throws -> DriveUploadResponse {
        let url = try XCTUnwrap(
            URL(string: "https://www.googleapis.com/upload/drive/v3/files")
        )
        return DriveUploadResponse(
            data: Data(body.utf8),
            response: try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
        )
    }

    private nonisolated static func cachedArtifactValidationSession(
        fileID: String,
        parentID: String,
        kind: String = "manifest",
        date: String? = nil
    ) -> URLSession {
        URLProtocolStub.setHandler { request in
            guard
                request.httpMethod == "GET",
                request.url?.path == "/drive/v3/files/\(fileID)"
            else {
                throw StubError.unexpectedRequest(
                    request.url?.absoluteString ?? "nil"
                )
            }
            var appProperties = ["healthMuleKind": kind]
            if let date {
                appProperties["healthMuleDate"] = date
            }
            return try Self.response(
                for: request,
                json: [
                    "id": fileID,
                    "name": date.map { "\($0).json" } ?? "manifest.json",
                    "mimeType": "application/json",
                    "trashed": false,
                    "parents": [parentID],
                    "appProperties": appProperties,
                ]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func metadataStateKey(
        for accountID: String
    ) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let namespace = digest.map { String(format: "%02x", $0) }.joined()
        return "drive.metadata.v2.\(namespace)"
    }
}

private struct TestSessionDriveUploadTransport: DriveUploadTransport {
    let session: URLSession

    func transition(toDestinationScopeID _: String?) async throws {}

    func upload(
        request: URLRequest,
        body: Data,
        operationID _: String,
        destinationScopeID _: String
    ) async throws -> DriveUploadResponse {
        var request = request
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return DriveUploadResponse(data: data, response: response)
    }
}

private actor RecordingDriveUploadTransport: DriveUploadTransport {
    struct Invocation: @unchecked Sendable {
        let request: URLRequest
        let body: Data
        let operationID: String
        let destinationScopeID: String
    }

    private let responseData: Data
    private let responseStatuses: [Int]
    private var invocations: [Invocation] = []
    private var responseIndex = 0
    private var destinationTransitions: [String?] = []

    init(
        responseJSON: Any,
        responseStatuses: [Int] = [200]
    ) throws {
        responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        self.responseStatuses = responseStatuses.isEmpty
            ? [200]
            : responseStatuses
    }

    func upload(
        request: URLRequest,
        body: Data,
        operationID: String,
        destinationScopeID: String
    ) async throws -> DriveUploadResponse {
        invocations.append(
            Invocation(
                request: request,
                body: body,
                operationID: operationID,
                destinationScopeID: destinationScopeID
            )
        )
        let status = responseStatuses[
            min(responseIndex, responseStatuses.count - 1)
        ]
        responseIndex += 1
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return DriveUploadResponse(data: responseData, response: response)
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }

    func recordedDestinationTransitions() -> [String?] {
        destinationTransitions
    }

    func transition(
        toDestinationScopeID destinationScopeID: String?
    ) async throws {
        destinationTransitions.append(destinationScopeID)
    }
}

private actor SuspendingDriveUploadTransport: DriveUploadTransport {
    private var uploadStarted = false
    private var uploadReleased = false
    private var uploadCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func transition(toDestinationScopeID _: String?) async throws {}

    func upload(
        request: URLRequest,
        body _: Data,
        operationID _: String,
        destinationScopeID _: String
    ) async throws -> DriveUploadResponse {
        uploadCount += 1
        uploadStarted = true
        let startWaiters = startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        if !uploadReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            throw URLError(.badServerResponse)
        }
        return DriveUploadResponse(
            data: Data(
                #"{"id":"stale-response-id","name":"manifest.json"}"#.utf8
            ),
            response: response
        )
    }

    func waitUntilUploadStarts() async {
        guard !uploadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseUpload() {
        uploadReleased = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }

    func recordedUploadCount() -> Int {
        uploadCount
    }
}

private actor SuspendingTransitionDriveUploadTransport:
    DriveUploadTransport
{
    private var transitionStarted = false
    private var transitionReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func transition(toDestinationScopeID _: String?) async throws {
        transitionStarted = true
        let startWaiters = startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !transitionReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func upload(
        request _: URLRequest,
        body _: Data,
        operationID _: String,
        destinationScopeID _: String
    ) async throws -> DriveUploadResponse {
        throw URLError(.unsupportedURL)
    }

    func waitUntilTransitionStarts() async {
        guard !transitionStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseTransition() {
        transitionReleased = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private actor AsyncSuspensionGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let suspensionWaiters = suspensionWaiters
        self.suspensionWaiters.removeAll()
        suspensionWaiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

private final class ManualExpiryScheduler: @unchecked Sendable {
    typealias Action = @Sendable () -> Void

    private let lock = NSLock()
    private var actions: [Action?] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    func schedule(_ action: @escaping Action) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    func runScheduledAction(at index: Int) {
        let action: Action?
        lock.lock()
        if actions.indices.contains(index) {
            action = actions[index]
            actions[index] = nil
        } else {
            action = nil
        }
        lock.unlock()
        action?()
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

private enum StubError: Error {
    case unexpectedRequest(String)
}

private final class BackgroundUploadURLProtocol: URLProtocol {
    private static let state = BackgroundUploadProtocolState()
    private let lifecycleLock = NSLock()
    private var lifecycleGeneration: UInt64?
    private var releaseResponse: DispatchSemaphore?
    private var isWaitingForRelease = false
    private var isStopped = false

    static var stopLoadingCount: Int {
        state.stopLoadingCount
    }

    static var startLoadingCount: Int {
        state.startLoadingCount
    }

    static var startedRequestPaths: [String] {
        state.startedRequestPaths
    }

    static func configure(
        requestStarted: XCTestExpectation,
        requestReleased: XCTestExpectation,
        releaseResponse: DispatchSemaphore,
        completionErrorCode: URLError.Code? = nil
    ) {
        state.configure(
            requestStarted: requestStarted,
            requestReleased: requestReleased,
            releaseResponse: releaseResponse,
            completionErrorCode: completionErrorCode
        )
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let context = Self.state.markStarted(requestPath: request.url?.path)
        lifecycleLock.lock()
        lifecycleGeneration = context.generation
        releaseResponse = context.releaseResponse
        isWaitingForRelease = true
        let stoppedBeforeStart = isStopped
        lifecycleLock.unlock()
        guard !stoppedBeforeStart else { return }

        let protocolBox = BackgroundUploadProtocolBox(value: self)
        DispatchQueue.global(qos: .userInitiated).async {
            let sourceProtocol = protocolBox.value
            let released = context.waitForRelease()
            sourceProtocol.finishWaitingForRelease()
            guard released else {
                sourceProtocol.client?.urlProtocol(
                    sourceProtocol,
                    didFailWithError: URLError(.timedOut)
                )
                return
            }
            Self.state.markReleased(generation: context.generation)
            guard !sourceProtocol.wasStopped else { return }
            if let completionErrorCode = context.completionErrorCode {
                sourceProtocol.client?.urlProtocol(
                    sourceProtocol,
                    didFailWithError: URLError(completionErrorCode)
                )
                return
            }
            guard
                let url = sourceProtocol.request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            else {
                sourceProtocol.client?.urlProtocol(
                    sourceProtocol,
                    didFailWithError: URLError(.badServerResponse)
                )
                return
            }
            sourceProtocol.client?.urlProtocol(
                sourceProtocol,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            sourceProtocol.client?.urlProtocol(
                sourceProtocol,
                didLoad: Data(
                    #"{"id":"manifest-a","name":"manifest.json"}"#.utf8
                )
            )
            sourceProtocol.client?.urlProtocolDidFinishLoading(sourceProtocol)
        }
    }

    override func stopLoading() {
        lifecycleLock.lock()
        isStopped = true
        let shouldReleaseWait = isWaitingForRelease
        isWaitingForRelease = false
        let generation = lifecycleGeneration
        let releaseResponse = releaseResponse
        lifecycleLock.unlock()
        if shouldReleaseWait {
            releaseResponse?.signal()
        }
        Self.state.recordStopLoading(generation: generation)
    }

    private func finishWaitingForRelease() {
        lifecycleLock.lock()
        isWaitingForRelease = false
        lifecycleLock.unlock()
    }

    private var wasStopped: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isStopped
    }
}

private struct BackgroundUploadProtocolBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class BackgroundUploadProtocolState: @unchecked Sendable {
    struct RequestContext: @unchecked Sendable {
        let generation: UInt64
        let releaseResponse: DispatchSemaphore
        let completionErrorCode: URLError.Code?

        func waitForRelease() -> Bool {
            releaseResponse.wait(timeout: .now() + 5) == .success
        }
    }

    private let lock = NSLock()
    private var requestStarted: XCTestExpectation?
    private var requestReleased: XCTestExpectation?
    private var releaseResponse: DispatchSemaphore?
    private var stopLoadingValue = 0
    private var startLoadingValue = 0
    private var startedRequestPathValues: [String] = []
    private var releasedRequestCount = 0
    private var completionErrorCodeValue: URLError.Code?
    private var generation: UInt64 = 0

    var stopLoadingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopLoadingValue
    }

    var startLoadingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startLoadingValue
    }

    var startedRequestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return startedRequestPathValues
    }

    func configure(
        requestStarted: XCTestExpectation,
        requestReleased: XCTestExpectation,
        releaseResponse: DispatchSemaphore,
        completionErrorCode: URLError.Code?
    ) {
        lock.lock()
        generation &+= 1
        self.requestStarted = requestStarted
        self.requestReleased = requestReleased
        self.releaseResponse = releaseResponse
        stopLoadingValue = 0
        startLoadingValue = 0
        startedRequestPathValues = []
        releasedRequestCount = 0
        completionErrorCodeValue = completionErrorCode
        lock.unlock()
    }

    func markStarted(requestPath: String?) -> RequestContext {
        lock.lock()
        startLoadingValue += 1
        if let requestPath {
            startedRequestPathValues.append(requestPath)
        }
        let expectation = startLoadingValue == 1 ? requestStarted : nil
        let context = RequestContext(
            generation: generation,
            releaseResponse: releaseResponse
                ?? DispatchSemaphore(value: 0),
            completionErrorCode: completionErrorCodeValue
        )
        lock.unlock()
        expectation?.fulfill()
        return context
    }

    func markReleased(generation: UInt64) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        releasedRequestCount += 1
        let expectation = releasedRequestCount == 1
            ? requestReleased
            : nil
        lock.unlock()
        expectation?.fulfill()
    }

    func recordStopLoading(generation: UInt64?) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        stopLoadingValue += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        generation &+= 1
        requestStarted = nil
        requestReleased = nil
        releaseResponse = nil
        stopLoadingValue = 0
        startLoadingValue = 0
        startedRequestPathValues = []
        releasedRequestCount = 0
        completionErrorCodeValue = nil
        lock.unlock()
    }
}

private final class URLProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerStore = HandlerStore()

    static func setHandler(_ handler: @escaping Handler) {
        handlerStore.set(handler)
    }

    static func removeHandler() {
        handlerStore.set(nil)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try Self.handlerStore.response(for: request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: URLProtocolStub.Handler?

    func set(_ handler: URLProtocolStub.Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else {
            throw StubError.unexpectedRequest(request.url?.absoluteString ?? "nil")
        }
        return try handler(request)
    }
}
