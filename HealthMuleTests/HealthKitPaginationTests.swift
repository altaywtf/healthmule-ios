@preconcurrency import HealthKit
import XCTest
@testable import HealthMule

final class HealthKitPaginationTests: XCTestCase {
    func testCancellationAfterFullPageStopsBeforeNextQuery() async throws {
        try await assertCancellationAfterPage(sampleCount: 500)
    }

    func testCancellationAfterFinalPageDoesNotReturnBatch() async throws {
        try await assertCancellationAfterPage(sampleCount: 1)
    }

    func testAlreadyCancelledTaskDoesNotQueryFirstPage() async throws {
        let client = HealthKitClient()
        let pages = try SyntheticHealthPages(sampleCounts: [1])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.anchoredQuery(anchor: nil) { cursor, limit in
                try await pages.fetch(anchor: cursor, limit: limit)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        let count = await pages.queryCount()
        XCTAssertEqual(count, 0)
    }

    func testUncancelledPaginationRetainsSamplesAndAdvancesAnchor() async throws {
        let client = HealthKitClient()
        let pages = try SyntheticHealthPages(sampleCounts: [500, 1])
        let result = try await client.anchoredQuery(anchor: nil) { cursor, limit in
            try await pages.fetch(anchor: cursor, limit: limit)
        }
        let count = await pages.queryCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result.samples.count, 501)
        XCTAssertTrue(result.deletedObjects.isEmpty)
        let finalAnchor = await pages.finalAnchor()
        XCTAssertTrue(result.anchor === finalAnchor)
    }

    private func assertCancellationAfterPage(sampleCount: Int) async throws {
        let client = HealthKitClient()
        let pages = try SyntheticHealthPages(
            sampleCounts: [sampleCount, 0],
            blockFirstPage: true
        )
        let task = Task {
            try await client.anchoredQuery(anchor: nil) { cursor, limit in
                try await pages.fetch(anchor: cursor, limit: limit)
            }
        }
        await pages.waitUntilFirstPageStarts()
        task.cancel()
        await pages.releaseFirstPage()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before returning the collected batch.")
        } catch is CancellationError {}
        let count = await pages.queryCount()
        XCTAssertEqual(count, 1)
    }
}

private actor SyntheticHealthPages {
    private let sample: HKQuantitySample
    private let sampleCounts: [Int]
    private let anchors: [HKQueryAnchor]
    private let blockFirstPage: Bool
    private var count = 0
    private var firstPageWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstPageContinuation: CheckedContinuation<Void, Never>?

    init(sampleCounts: [Int], blockFirstPage: Bool = false) throws {
        self.sampleCounts = sampleCounts
        anchors = sampleCounts.indices.map { HKQueryAnchor(fromValue: $0 + 1) }
        self.blockFirstPage = blockFirstPage
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: 1),
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 1_001)
        )
    }

    func fetch(anchor: HKQueryAnchor?, limit: Int) async throws -> (
        samples: [HKSample], deletedObjects: [HKDeletedObject], anchor: HKQueryAnchor
    ) {
        XCTAssertTrue(anchor === (count == 0 ? nil : anchors[count - 1]))
        XCTAssertEqual(limit, 500)
        let sampleCount = sampleCounts[count]
        count += 1
        if blockFirstPage, count == 1 {
            let waiters = firstPageWaiters
            firstPageWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { firstPageContinuation = $0 }
        }
        return (Array(repeating: sample, count: sampleCount), [], anchors[count - 1])
    }

    func waitUntilFirstPageStarts() async {
        guard count == 0 else { return }
        await withCheckedContinuation { firstPageWaiters.append($0) }
    }

    func releaseFirstPage() {
        firstPageContinuation?.resume()
        firstPageContinuation = nil
    }

    func queryCount() -> Int { count }

    func finalAnchor() -> HKQueryAnchor { anchors[anchors.count - 1] }
}
