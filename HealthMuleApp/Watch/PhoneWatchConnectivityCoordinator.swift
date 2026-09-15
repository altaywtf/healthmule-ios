import Foundation
import HealthMuleCompanion
@preconcurrency import WatchConnectivity

private final class CompanionReply: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(accepted: Bool) {
        handler(CompanionPayloadCodec.acknowledgement(accepted: accepted))
    }
}

@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject {
    typealias SnapshotProvider =
        @MainActor @Sendable () -> CompanionSyncSnapshot?
    typealias SyncRequestHandler = @MainActor @Sendable () async -> Void

    private let session: WCSession?
    private let snapshotProvider: SnapshotProvider
    private let syncRequestHandler: SyncRequestHandler
    private var publicationState = CompanionSnapshotPublicationState()

    init(
        snapshotProvider: @escaping SnapshotProvider,
        syncRequestHandler: @escaping SyncRequestHandler,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.snapshotProvider = snapshotProvider
        self.syncRequestHandler = syncRequestHandler
        self.session = session
        super.init()
    }

    func activate() {
        publicationState.invalidate()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func publishCurrentStatus() {
        guard
            let session,
            session.activationState == .activated,
            let snapshot = snapshotProvider(),
            publicationState.needsPublication(of: snapshot),
            let message = try? CompanionPayloadCodec.message(
                snapshot: snapshot
            )
        else {
            return
        }
        do {
            try session.updateApplicationContext(message)
            publicationState.didPublish(snapshot)
        } catch {}
        for transfer in session.outstandingUserInfoTransfers {
            transfer.cancel()
        }
        session.transferUserInfo(message)
    }

    private func handleSyncRequest() async {
        await syncRequestHandler()
        publishCurrentStatus()
    }
}

extension PhoneWatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.publishCurrentStatus()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publicationState.invalidate()
            self?.session?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publicationState.invalidate()
            self?.publishCurrentStatus()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard
            (try? CompanionPayloadCodec.syncRequest(from: message)) != nil
        else {
            replyHandler(CompanionPayloadCodec.acknowledgement(accepted: false))
            return
        }

        let reply = CompanionReply(replyHandler)
        Task { @MainActor [weak self] in
            guard
                let self,
                snapshotProvider()?.canRequestSync == true
            else {
                reply.send(accepted: false)
                return
            }
            reply.send(accepted: true)
            await handleSyncRequest()
        }
    }
}
