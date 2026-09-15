import Foundation
import HealthMuleCompanion
import Observation
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class CompanionAppModel: NSObject {
    private(set) var snapshot: CompanionSyncSnapshot?
    private(set) var isReachable = false
    private(set) var activationState: CompanionActivationState = .inactive
    private var requestLifecycle = CompanionRequestLifecycle()

    private let session: WCSession?

    init(
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.session = session
        super.init()
        session?.delegate = self
    }

    var canRequestSync: Bool {
        status(at: .now).canRequestSync
    }

    func status(at now: Date) -> CompanionStatusModel {
        CompanionStatusModel(
            snapshot: snapshot,
            activation: activationState,
            isReachable: isReachable,
            requestState: requestLifecycle.state,
            now: now
        )
    }

    func activate() {
        guard let session else {
            activationState = .failed
            return
        }
        receiveSnapshot(from: session.receivedApplicationContext)
        activationState = session.activationState == .activated
            ? .activated
            : .inactive
        isReachable = session.isReachable
        session.activate()
    }

    func requestSync() {
        guard canRequestSync, let session else { return }
        let request = CompanionSyncRequest()
        requestLifecycle.start(
            requestID: request.id,
            baseline: snapshot
        )
        guard
            let message = try? CompanionPayloadCodec.message(
                syncRequest: request
            )
        else {
            requestLifecycle.receiveReply(
                requestID: request.id,
                accepted: false
            )
            return
        }

        // WatchConnectivity invokes these on its own operation queue. Both must
        // stay @Sendable: a closure literal written inside this @MainActor type
        // is otherwise inferred main-actor isolated, and the compiler emits a
        // runtime isolation assertion that traps the moment the phone replies.
        let requestID = request.id
        session.sendMessage(
            message,
            replyHandler: { @Sendable [weak self] reply in
                let accepted = CompanionPayloadCodec.isAccepted(reply)
                Task { @MainActor in
                    self?.completeRequest(requestID, accepted: accepted)
                }
            },
            errorHandler: { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.completeRequest(requestID, accepted: false)
                }
            }
        )
    }

    private func completeRequest(_ requestID: UUID, accepted: Bool) {
        requestLifecycle.receiveReply(
            requestID: requestID,
            accepted: accepted
        )
        if requestLifecycle.state == .accepted {
            resetAcceptedStateIfNeeded(for: requestID)
        }
    }

    private func resetAcceptedStateIfNeeded(for requestID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard
                !Task.isCancelled,
                let self,
                requestLifecycle.requestID == requestID,
                requestLifecycle.state == .accepted
            else {
                return
            }
            requestLifecycle.acceptedStateExpired(requestID: requestID)
        }
    }

    private func receiveSnapshot(from message: [String: Any]) {
        guard
            let snapshot = try? CompanionPayloadCodec.snapshot(from: message)
        else {
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: CompanionSyncSnapshot) {
        self.snapshot = snapshot
        requestLifecycle.receive(snapshot: snapshot)
    }
}

extension CompanionAppModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith receivedActivationState:
            WCSessionActivationState,
        error: (any Error)?
    ) {
        let isActivated =
            receivedActivationState == .activated && error == nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReachable = isActivated && self.session?.isReachable == true
            if isActivated {
                self.activationState = .activated
                if let context = self.session?.receivedApplicationContext {
                    receiveSnapshot(from: context)
                }
            } else {
                self.activationState = .failed
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        receiveRemoteSnapshot(from: applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        receiveRemoteSnapshot(from: userInfo)
    }

    nonisolated private func receiveRemoteSnapshot(
        from payload: [String: Any]
    ) {
        guard
            let snapshot = try? CompanionPayloadCodec.snapshot(from: payload)
        else {
            return
        }
        Task { @MainActor [weak self] in
            self?.apply(snapshot)
        }
    }
}
