import Foundation
import XCTest
@testable import HealthMule

final class SyncActivityStoreTests: XCTestCase {
    func testReceiptRoundTripsWithoutSensitivePayloadFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_787_000_000)
        let store = SyncActivityStore(directoryURL: directory, now: { timestamp })

        let id = try await store.begin(trigger: .backgroundRefresh)
        try await store.finish(
            id: id,
            outcome: .pending,
            counts: SyncActivityCounts(
                staged: 2,
                uploaded: 1,
                pending: 1,
                failed: 0
            )
        )

        let reopened = SyncActivityStore(directoryURL: directory)
        let reopenedSnapshot = try await reopened.snapshot()
        let receipt = try XCTUnwrap(reopenedSnapshot.receipts.first)
        XCTAssertEqual(receipt.trigger, .backgroundRefresh)
        XCTAssertEqual(receipt.outcome, .pending)
        XCTAssertEqual(receipt.counts.pending, 1)

        let data = try Data(contentsOf: activityFile(in: directory))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbiddenField in [
            "record", "metadata", "token", "fileName", "driveFileID",
            "healthValue",
        ] {
            XCTAssertFalse(json.contains(forbiddenField))
        }
    }

    func testStoreKeepsOnlyTwentyNewestReceipts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_787_000_000)
        var ids = (0 ..< 20).map { _ in UUID() }
        let preservedID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        )
        ids.append(preservedID)

        for generatedID in ids {
            let store = SyncActivityStore(
                directoryURL: directory,
                now: { timestamp },
                makeID: { generatedID }
            )
            let id = try await store.begin(trigger: .foreground)
            try await store.finish(id: id, outcome: .succeeded)
        }

        let store = SyncActivityStore(directoryURL: directory)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.receipts.count, 20)
        XCTAssertTrue(snapshot.receipts.contains { $0.id == preservedID })
    }

    func testRunningReceiptRecoversAsInterrupted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let interruptedAt = startedAt.addingTimeInterval(60)
        let firstStore = SyncActivityStore(
            directoryURL: directory,
            now: { startedAt }
        )
        let id = try await firstStore.begin(trigger: .healthObserver)

        let reopened = SyncActivityStore(
            directoryURL: directory,
            now: { interruptedAt }
        )
        let reopenedSnapshot = try await reopened.snapshot()
        let receipt = try XCTUnwrap(reopenedSnapshot.receipts.first)

        XCTAssertEqual(receipt.id, id)
        XCTAssertEqual(receipt.outcome, .interrupted)
        XCTAssertEqual(receipt.reason, .processInterrupted)
        XCTAssertEqual(receipt.finishedAt, interruptedAt)

        let persistedAgain = SyncActivityStore(directoryURL: directory)
        let persistedSnapshot = try await persistedAgain.snapshot()
        XCTAssertEqual(persistedSnapshot.receipts.first, receipt)
    }

    func testCorruptStateIsSurfacedWithoutOverwrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corruptData = Data("not-json".utf8)
        let fileURL = activityFile(in: directory)
        try corruptData.write(to: fileURL, options: .atomic)
        let store = SyncActivityStore(directoryURL: directory)

        do {
            _ = try await store.snapshot()
            XCTFail("Expected corrupt state to fail")
        } catch {
            XCTAssertEqual(error as? SyncActivityStoreError, .invalidState)
        }
        do {
            _ = try await store.begin(trigger: .manual)
            XCTFail("Expected corrupt state to fail")
        } catch {
            XCTAssertEqual(error as? SyncActivityStoreError, .invalidState)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
    }

    func testPersistedFileUsesProtectedStorageAndSkipsBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncActivityStore(directoryURL: directory)

        _ = try await store.begin(trigger: .appLaunch)

        XCTAssertEqual(
            SyncActivityStoragePolicy.directoryProtection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertTrue(
            SyncActivityStoragePolicy.fileWriteOptions.contains(
                .completeFileProtectionUntilFirstUserAuthentication
            )
        )
        XCTAssertTrue(
            SyncActivityStoragePolicy.fileWriteOptions.contains(.atomic)
        )
        XCTAssertTrue(SyncActivityStoragePolicy.excludesFromBackup)

        let fileURL = activityFile(in: directory)
        try PersistedStorageAssertions.assertProtectedAndExcludedFromBackup(
            fileURL,
            expectedProtection: SyncActivityStoragePolicy.directoryProtection,
            excludesFromBackup: SyncActivityStoragePolicy.excludesFromBackup
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "healthmule-sync-activity-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func activityFile(in directory: URL) -> URL {
        directory.appendingPathComponent(
            "sync-activity.json",
            isDirectory: false
        )
    }
}
