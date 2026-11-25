import Foundation

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

    static let shared = NativeEmailVerificationCoordinator()

    private var inFlight: [HubWebViewController.NativeEmailVerificationParameters: Task<Outcome, Never>] = [:]

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
        let task = Task.detached(priority: .userInitiated, operation: operation)
        inFlight[parameters] = task
        let outcome = await task.value
        inFlight[parameters] = nil
        return outcome
    }
}
