import Foundation
import UIKit

/// What the app held when a native verification started.
///
/// The Rownd store can legitimately lag the SDK (a soft-failed startup reconcile, a failed
/// persist, or state reloaded from a shared keychain). Comparing against this snapshot
/// keeps a store that merely never caught up from being mistaken for a newer session.
struct NativeEmailVerificationStart: Sendable {
    let permit: SuperTokensSessionBridge.AuthOperationPermit
    let previousAccessToken: String?
    let rowndAccessToken: String?

    var isPermitValid: Bool {
        SuperTokensSessionBridge.isAuthOperationPermitValid(permit)
    }

    /// The store still follows this verification: it is on S0 or S1, or it has not moved
    /// since the request started.
    func storeFollowsVerification(_ rowndAccessToken: String?, issuedAccessToken: String?) -> Bool {
        rowndAccessToken == self.rowndAccessToken
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, self.rowndAccessToken)
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, previousAccessToken)
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, issuedAccessToken)
    }
}

/// The server issued a session in the verification response, but it was not adopted.
struct NativeEmailVerificationUnadoptedSessionError: Error, CustomStringConvertible {
    let issuedAccessToken: String
    let underlying: Error

    // Keeps the issued token out of logs.
    var description: String {
        "Issued session was not adopted: \(String(describing: underlying))"
    }
}

/// Runs native email verifications independently of the Hub page that requested them.
///
/// The server revokes the initiating session and returns its replacement in the
/// verification response. If the response were dropped because the Hub sheet was
/// dismissed or navigated, the app would keep a revoked session. Only delivering the
/// outcome back to the Hub depends on the requesting page still being current.
actor NativeEmailVerificationCoordinator {
    enum Outcome: Equatable, Sendable {
        case verified
        case failed(FailureRecovery)
    }

    enum FailureRecovery: Equatable, Sendable {
        /// The server still accepts the session that started the verification.
        case sessionRetained
        /// The verification committed and its replacement session was adopted.
        case replacementAdopted
        /// The server revoked the initiating session, so Rownd signed out.
        case signedOut
        /// The local session changed for unrelated reasons; nothing was touched.
        case superseded
        /// The server was unreachable; the local session was kept as is.
        case unresolved
    }

    /// Starts keeping the app running and returns the closure that releases it.
    typealias BeginBackgroundExecution = @MainActor @Sendable () -> @Sendable () -> Void

    static let shared = NativeEmailVerificationCoordinator()

    private var inFlight: [HubWebViewController.NativeEmailVerificationParameters: Task<Outcome, Never>] = [:]
    private let beginBackgroundExecution: BeginBackgroundExecution

    init(beginBackgroundExecution: @escaping BeginBackgroundExecution = NativeEmailVerificationCoordinator.beginApplicationBackgroundTask) {
        self.beginBackgroundExecution = beginBackgroundExecution
    }

    /// Backgrounding the app must not suspend a verification whose response carries
    /// the only copy of the replacement session.
    @MainActor static func beginApplicationBackgroundTask() -> @Sendable () -> Void {
        let release = BackgroundTaskRelease()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Rownd email verification") {
            release.run()
        }
        guard identifier != .invalid else { return {} }
        release.set {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(identifier) }
        }
        return { release.run() }
    }

    /// A Hub page reloaded during a verification asks again with the same parameters;
    /// it joins the running request instead of replaying it with a session the first
    /// request may already have revoked.
    func verify(
        _ parameters: HubWebViewController.NativeEmailVerificationParameters,
        operation: @escaping @Sendable () async -> Outcome
    ) async -> Outcome {
        if let running = inFlight[parameters] {
            return await running.value
        }
        let beginBackgroundExecution = beginBackgroundExecution
        let task = Task.detached(priority: .userInitiated) { () -> Outcome in
            let endBackgroundExecution = await beginBackgroundExecution()
            defer { endBackgroundExecution() }
            return await operation()
        }
        inFlight[parameters] = task
        let outcome = await task.value
        inFlight[parameters] = nil
        return outcome
    }
}

/// Ends a background task exactly once, whether it finishes or its time expires first.
private final class BackgroundTaskRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var hasRun = false

    func set(_ action: @escaping () -> Void) {
        lock.lock()
        let alreadyRan = hasRun
        if !alreadyRan { self.action = action }
        lock.unlock()
        if alreadyRan { action() }
    }

    func run() {
        lock.lock()
        let action = self.action
        self.action = nil
        hasRun = true
        lock.unlock()
        action?()
    }
}
