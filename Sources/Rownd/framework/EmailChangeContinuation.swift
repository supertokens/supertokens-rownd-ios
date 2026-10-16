import Foundation

struct EmailChangeDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let requestId: String
    let localDraft: LocalDraft
    let expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case version
        case requestId = "request_id"
        case localDraft = "local_draft"
        case expiresAt = "expires_at"
    }

    struct LocalDraft: Codable, Equatable, Sendable {
        let ownerId: String
        let tenantId: String
        let configuration: String
        let changes: Changes
        enum CodingKeys: String, CodingKey {
            case ownerId = "owner_id", tenantId = "tenant_id", configuration, changes
        }
    }
    struct Changes: Codable, Equatable, Sendable { let email: String }

    func isValid(now: Date) -> Bool {
        version == 2 && requestId.utf8.count >= 16 && Self.validIdentifier(requestId, maximum: 128)
            && isLive(now: now)
            && [localDraft.ownerId, localDraft.tenantId].allSatisfy { !$0.isEmpty && $0.utf16.count <= 256 }
            && !localDraft.configuration.isEmpty && localDraft.configuration.utf16.count <= 4096
            && !localDraft.changes.email.isEmpty && localDraft.changes.email.utf16.count <= 254
            && ((try? JSONEncoder().encode(self).count) ?? Int.max) <= 32 * 1024
    }

    func isLive(now: Date) -> Bool {
        let remaining = expiresAt - now.timeIntervalSince1970 * 1000
        return expiresAt.isFinite && expiresAt.rounded() == expiresAt && remaining > 0 && remaining <= 15 * 60 * 1000
    }

    static func validIdentifier(_ value: String, maximum: Int = 256) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

/// In-process form input and ownership; never restored after process death.
@MainActor final class EmailChangeContinuation {
    struct AuthenticationContext: Equatable, Sendable {
        let owner: UUID
        let requestId: String
        let configuration: String

        func replacingOwner(_ owner: UUID) -> AuthenticationContext {
            AuthenticationContext(owner: owner, requestId: requestId, configuration: configuration)
        }
    }
    enum Phase { case cleaning, signingIn, resume }
    struct Record {
        let descriptor: EmailChangeDescriptor
        let configuration: String
        var phase: Phase
        var challengeId: String?
    }

    private let now: () -> Date
    private let invalidateAuthentication: () -> Void
    private(set) var record: Record?
    private(set) var owner: UUID?
    private var expectedDismissal: UUID?

    init(now: @escaping () -> Date = Date.init,
         invalidateAuthentication: @escaping () -> Void = {}) {
        self.now = now
        self.invalidateAuthentication = invalidateAuthentication
    }

    func validate(configuration: String) -> Bool {
        guard !configuration.isEmpty, let record, record.configuration == configuration,
              record.descriptor.isLive(now: now()) else {
            clear()
            return false
        }
        return true
    }

    func begin(_ descriptor: EmailChangeDescriptor, configuration: String, owner: UUID) -> Bool {
        guard record == nil, !configuration.isEmpty, descriptor.isValid(now: now()) else { return false }
        self.owner = owner
        expectedDismissal = nil
        record = Record(descriptor: descriptor, configuration: configuration, phase: .cleaning)
        return true
    }

    func cleaned(owner: UUID) -> Bool {
        guard self.owner == owner, record?.phase == .cleaning else { return false }
        record?.phase = .signingIn
        return true
    }

    func ownsSignIn(_ owner: UUID) -> Bool {
        self.owner == owner && record?.phase == .signingIn
    }

    func authenticationContext(owner: UUID) -> AuthenticationContext? {
        guard ownsSignIn(owner), let record, record.descriptor.isLive(now: now()) else { return nil }
        return AuthenticationContext(owner: owner, requestId: record.descriptor.requestId, configuration: record.configuration)
    }

    func ownsAuthentication(_ context: AuthenticationContext) -> Bool {
        authenticationContext(owner: context.owner) == context
    }

    func registerChallenge(_ challenge: String, owner: UUID) {
        guard ownsSignIn(owner), EmailChangeDescriptor.validIdentifier(challenge) else { return }
        record?.challengeId = challenge
    }

    func clearChallenge(owner: UUID) {
        guard ownsSignIn(owner) else { return }
        record?.challengeId = nil
    }

    func transfer(from: UUID, to: UUID) -> Bool {
        guard ownsSignIn(from) else { return false }
        owner = to
        return true
    }

    func claimCallback(_ url: URL, owner: UUID, hubURL: String, apiDomain: String, apiBasePath: String) -> Bool {
        guard record?.phase == .signingIn, let challenge = record?.challengeId,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let hub = URLComponents(string: hubURL),
              parts.scheme == hub.scheme, parts.host == hub.host, parts.port == hub.port,
              parts.path == "/account/login" else { return false }
        let identifiers = (parts.queryItems ?? []).filter { $0.name == "preAuthSessionId" }
        guard identifiers.count == 1, identifiers.first?.value == challenge else { return false }
        for (name, expected) in [("apiDomain", apiDomain), ("apiBasePath", apiBasePath)] {
            let values = (parts.queryItems ?? []).filter { $0.name == name }
            guard values.count <= 1, values.isEmpty || values.first?.value == expected else { return false }
        }
        // Consume local callback ownership before loading any web content.
        record?.challengeId = nil
        self.owner = owner
        return true
    }

    func adopted(owner: UUID) -> Bool {
        guard ownsSignIn(owner) else { return false }
        record?.phase = .resume
        record?.challengeId = nil
        expectedDismissal = owner
        return true
    }

    func bindResume(owner: UUID) -> EmailChangeDescriptor? {
        guard record?.phase == .resume else { return nil }
        self.owner = owner
        return record?.descriptor
    }

    func takeResume(owner: UUID) -> EmailChangeDescriptor? {
        guard self.owner == owner, record?.phase == .resume,
              let descriptor = record?.descriptor, descriptor.isLive(now: now()) else { return nil }
        clear() // Consume the routing permit before asynchronous JavaScript delivery.
        return descriptor
    }

    func expectDismissal(owner: UUID) { expectedDismissal = owner }

    func dismissed(owner: UUID) {
        if expectedDismissal == owner {
            expectedDismissal = nil
        } else if self.owner == owner, record?.phase != .cleaning {
            clear()
        }
    }

    func clear() {
        if record?.phase == .signingIn { invalidateAuthentication() }
        record = nil
        owner = nil
        expectedDismissal = nil
    }
}
