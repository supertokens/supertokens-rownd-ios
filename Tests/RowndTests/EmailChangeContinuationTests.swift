import Foundation
import Testing
import WebKit

@testable import Rownd

let emailChangeTestDraft = EmailChangeDescriptor.LocalDraft(ownerId: "owner", tenantId: "public", configuration: "config",
                                                          changes: .init(email: "destination@example.test"))

@Suite(.serialized) struct EmailChangeContinuationTests {
    private var descriptor: EmailChangeDescriptor {
        EmailChangeDescriptor(version: 2, requestId: UUID().uuidString, localDraft: emailChangeTestDraft,
                              expiresAt: (Date().addingTimeInterval(600).timeIntervalSince1970 * 1000).rounded())
    }

    @Test @MainActor func warmCallbackRequiresOwnedChallengeAndCannotSurviveNewInstance() {
        let store = EmailChangeContinuation()
        let owner = UUID()
        #expect(store.begin(descriptor, configuration: "config", owner: owner))
        #expect(store.cleaned(owner: owner))
        @MainActor func claim(_ store: EmailChangeContinuation, _ query: String) -> Bool {
            store.claimCallback(URL(string: "https://hub.example/account/login?\(query)")!, owner: UUID(),
                hubURL: "https://hub.example", apiDomain: "https://api.example", apiBasePath: "/auth")
        }
        #expect(!claim(store, "preAuthSessionId=owned"))
        store.registerChallenge("owned", owner: owner)
        #expect(!claim(EmailChangeContinuation(), "preAuthSessionId=owned"))
        #expect(!claim(store, "preAuthSessionId=wrong"))
        #expect(!claim(store, "preAuthSessionId=owned&preAuthSessionId=owned"))
        #expect(!claim(store, "preAuthSessionId=owned&apiDomain=https://evil.example"))
        #expect(claim(store, "preAuthSessionId=owned"))
        #expect(!claim(store, "preAuthSessionId=owned"))
    }

    @Test @MainActor func deliveryConsumesPermitBeforeDispatchAndNeverRestores() {
        let store = EmailChangeContinuation()
        let owner = UUID(), profile = UUID()
        let saved = descriptor
        #expect(store.begin(saved, configuration: "config", owner: owner))
        #expect(store.takeResume(owner: owner) == nil)
        #expect(store.cleaned(owner: owner))
        #expect(!store.adopted(owner: UUID()))
        #expect(store.adopted(owner: owner))
        store.dismissed(owner: owner)
        #expect(store.bindResume(owner: profile) == saved)
        #expect(!store.begin(saved, configuration: "config", owner: profile))
        #expect(store.takeResume(owner: owner) == nil)
        #expect(store.takeResume(owner: profile) == saved)
        #expect(store.record == nil)
        #expect(store.takeResume(owner: profile) == nil)
        #expect(EmailChangeContinuation().record == nil)
    }

    @Test @MainActor func expiryConfigurationAndCancellationInvalidateAuthentication() {
        var now = Date()
        var invalidations = 0
        let store = EmailChangeContinuation(now: { now }, invalidateAuthentication: { invalidations += 1 })
        let owner = UUID()
        for reason in 0..<3 {
            #expect(store.begin(descriptor, configuration: "config", owner: owner))
            #expect(store.cleaned(owner: owner))
            if reason == 0 { store.dismissed(owner: owner) }
            if reason == 1 { #expect(!store.validate(configuration: "different")) }
            if reason == 2 { now = now.addingTimeInterval(901); #expect(!store.validate(configuration: "config")) }
            #expect(!store.adopted(owner: owner))
        }
        #expect(invalidations == 3)
    }

    @Test func rejectsOldOversizeCredentialAndInvalidExpiryEnvelopes() throws {
        let saved = descriptor
        #expect(saved.isValid(now: Date()))
        for value in [EmailChangeDescriptor(version: 1, requestId: saved.requestId, localDraft: saved.localDraft, expiresAt: saved.expiresAt),
                      EmailChangeDescriptor(version: 2, requestId: "short", localDraft: saved.localDraft, expiresAt: saved.expiresAt),
                      EmailChangeDescriptor(version: 2, requestId: saved.requestId, localDraft: saved.localDraft, expiresAt: saved.expiresAt + 0.5)] {
            #expect(!value.isValid(now: Date()))
        }
        for changes in [#"{"access_token":"secret"}"#, #"{"nested":{"return_url":"https://evil.example"}}"#,
                        "{\"email\":\"\(String(repeating: "a", count: 33 * 1024))\"}"] {
            let message = "{\"type\":\"sign_in\",\"payload\":{\"was_user_initiated\":true,\"email_change\":{\"version\":2,\"request_id\":\"\(saved.requestId)\",\"expires_at\":\(saved.expiresAt),\"local_draft\":{\"owner_id\":\"owner\",\"tenant_id\":\"public\",\"configuration\":\"config\",\"changes\":\(changes)}}}}"
            #expect(throws: (any Error).self) { try RowndHubInteropMessage.fromJson(message: message) }
        }
        #expect(throws: (any Error).self) {
            try RowndHubInteropMessage.fromJson(message: #"{"type":"sign_in","payload":{"was_user_initiated":true,"email_change":{"version":1,"request_id":"old-request-123456","draft_id":"old-draft","expires_at":1790000000000}}}"#)
        }
        #expect(!HubWebViewController.canHandleAuthentication(on: .manageAccount))
    }

    @Test func nativeContractRejectsNonEmailChangesBeforeAdmission() throws {
        for changes in [#"{"email":"destination@example.test","nickname":"already-saved"}"#, #"{"nickname":"already-saved"}"#,
                        #"{"email":""}"#, #"{"email":42}"#, "{\"email\":\"\(String(repeating: "a", count: 255))\"}"] {
            let message = "{\"type\":\"sign_in\",\"payload\":{\"was_user_initiated\":true,\"email_change\":{\"version\":2,\"request_id\":\"request-123456789\",\"expires_at\":\(descriptor.expiresAt),\"local_draft\":{\"owner_id\":\"owner\",\"tenant_id\":\"public\",\"configuration\":\"config\",\"changes\":\(changes)}}}}"
            let decoded = try? RowndHubInteropMessage.fromJson(message: message)
            if case .signIn(let payload) = decoded?.payload {
                #expect(payload.emailChange?.isValid(now: Date()) != true)
            }
        }
    }

    @Test @MainActor func cleanupAwaitsHubAndAPICookiesAndPreservesUnrelatedDomain() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        func cookie(_ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "auth-test", .value: "value", .secure: "TRUE"])!
        }
        for domain in ["hub.example.test", ".api.example.test", "unrelated.test"] {
            await dataStore.httpCookieStore.setCookie(cookie(domain))
        }
        try await HubWebsiteDataCleaner.clearAuthentication(hubURL: "https://hub.example.test", apiURL: "https://api.example.test", dataStore: dataStore)
        let remaining = await dataStore.httpCookieStore.allCookies()
        #expect(remaining.map(\.domain) == ["unrelated.test"])
        await #expect(throws: (any Error).self) {
            try await HubWebsiteDataCleaner.clearAuthentication(hubURL: "invalid", apiURL: "https://api.example.test", dataStore: dataStore)
        }
    }
}
