import Foundation
import UIKit

struct NativeEmailVerificationEndpoint: Hashable, Sendable {
    let apiDomain: String
    let apiBasePath: String
    let keychainAccessGroup: String?

    init(_ config: RowndSuperTokensConfig) {
        apiDomain = config.apiDomain
        apiBasePath = config.apiBasePath
        keychainAccessGroup = config.keychainAccessGroup
    }
}

struct NativeEmailVerificationStart: Sendable {
    let ownership: SuperTokensSessionBridge.VerificationOwnership
    let tokens: SuperTokensSessionTokens
    let owner: SuperTokensSessionBridge.StableSessionIdentity
    let storeID: ObjectIdentifier
    let rowndAccessToken: String?
    let endpoint: NativeEmailVerificationEndpoint

    var previousAccessToken: String { tokens.accessToken }

    @MainActor func mayCommit(issuedAccessToken: String? = nil) -> Bool {
        let store = Context.currentContext.store
        let currentToken = store.state.auth.accessToken
        return !Rownd.isSigningOut
            && SuperTokensSessionBridge.ownsVerification(ownership)
            && endpoint == NativeEmailVerificationEndpoint(Rownd.config.supertokens)
            && ObjectIdentifier(store) == storeID
            && storeFollowsVerification(currentToken, issuedAccessToken: issuedAccessToken)
    }

    private func storeFollowsVerification(_ rowndAccessToken: String?, issuedAccessToken: String?) -> Bool {
        // Startup reconciliation can hydrate S0 or clear its revoked credentials without a sign-in/out.
        rowndAccessToken == nil
            || rowndAccessToken == self.rowndAccessToken
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, self.rowndAccessToken)
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, previousAccessToken)
            || SuperTokensSessionBridge.tokensBelongToSameSession(rowndAccessToken, issuedAccessToken)
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

    struct Key: Hashable, Sendable {
        let parameters: HubWebViewController.NativeEmailVerificationParameters
        let endpoint: NativeEmailVerificationEndpoint
        let owner: SuperTokensSessionBridge.StableSessionIdentity
        let ownership: SuperTokensSessionBridge.VerificationOwnership
        let storeID: ObjectIdentifier
    }

    private var inFlight: [Key: Task<Outcome, Never>] = [:]
    private let beginBackgroundExecution: BeginBackgroundExecution

    init(beginBackgroundExecution: @escaping BeginBackgroundExecution = { beginApplicationBackgroundTask() }) {
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
        _ key: Key,
        operation: @escaping @Sendable () async -> Outcome
    ) async -> Outcome {
        if let running = inFlight[key] {
            return await running.value
        }
        let beginBackgroundExecution = beginBackgroundExecution
        let task = Task.detached(priority: .userInitiated) { () -> Outcome in
            let endBackgroundExecution = await beginBackgroundExecution()
            defer { endBackgroundExecution() }
            return await operation()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }

    func join(_ key: Key) async -> Outcome {
        guard let running = inFlight[key] else { return .failed(.superseded) }
        return await running.value
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
