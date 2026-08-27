import Testing
import Foundation

@testable import Rownd

@Suite(.serialized) struct RowndHubInteropMessageTests {
    @Test func authenticationMessageDecodesAntiCSRF() throws {
        let message = try RowndHubInteropMessage.fromJson(message: #"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token","front_token":"front-token","anti_csrf":"anti-csrf-token"}}"#)

        guard case .authentication(let payload) = message.payload else {
            Issue.record("Expected authentication payload")
            return
        }

        #expect(payload.accessToken == "access-token")
        #expect(payload.refreshToken == "refresh-token")
        #expect(payload.frontToken == "front-token")
        #expect(payload.antiCSRF == "anti-csrf-token")
    }

    @Test func authenticationMessageDecodesFrontToken() throws {
        let message = try RowndHubInteropMessage.fromJson(message: #"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token","front_token":"front-token"}}"#)

        guard case .authentication(let payload) = message.payload else {
            Issue.record("Expected authentication payload")
            return
        }

        #expect(payload.accessToken == "access-token")
        #expect(payload.refreshToken == "refresh-token")
        #expect(payload.frontToken == "front-token")
    }

    @Test func authenticationMessageRequiresRefreshToken() throws {
        assertAuthenticationMessageDecodeFails(#"{"type":"authentication","payload":{"access_token":"access-token","front_token":"front-token"}}"#)
        assertAuthenticationMessageDecodeFails(#"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":null,"front_token":"front-token"}}"#)
    }

    @Test func authenticationMessageRequiresFrontToken() throws {
        assertAuthenticationMessageDecodeFails(#"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token"}}"#)
        assertAuthenticationMessageDecodeFails(#"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token","front_token":null}}"#)
    }

    @Test func authenticationMessagesAreHandledForSignInAndDeepLinkPages() {
        #expect(HubWebViewController.canHandleAuthentication(on: .signIn))
        #expect(HubWebViewController.canHandleAuthentication(on: .deepLink))
        #expect(!HubWebViewController.canHandleAuthentication(on: .manageAccount))
        #expect(!HubWebViewController.canHandleAuthentication(on: nil))
    }

    @Test func signInCompletionHubEventIsSuppressedOnAuthenticationPages() {
        let signInCompleted = RowndEvent(event: .signInCompleted)
        let userUpdated = RowndEvent(event: .userUpdated)

        #expect(!HubWebViewController.shouldForwardHubEvent(signInCompleted, on: .signIn))
        #expect(!HubWebViewController.shouldForwardHubEvent(signInCompleted, on: .deepLink))
        #expect(HubWebViewController.shouldForwardHubEvent(signInCompleted, on: .manageAccount))
        #expect(HubWebViewController.shouldForwardHubEvent(userUpdated, on: .signIn))
    }

    @Test func failedSessionAdoptionSkipsAuthenticationCompletion() async {
        var didSyncAuthState = false
        var didComplete = false

        await HubWebViewController.completeAuthenticationAfterAdoption(
            succeeded: false,
            syncAuthState: {
                didSyncAuthState = true
                return true
            },
            syncFailure: {},
            completion: { didComplete = true }
        )

        #expect(!didSyncAuthState)
        #expect(!didComplete)
    }

    @Test func failedAuthStateSyncSkipsAuthenticationCompletion() async {
        var steps: [String] = []

        await HubWebViewController.completeAuthenticationAfterAdoption(
            succeeded: true,
            syncAuthState: {
                steps.append("sync")
                return false
            },
            syncFailure: { steps.append("show-error") },
            completion: { steps.append("complete") }
        )

        #expect(steps == ["sync", "show-error"])
    }

    @Test func successfulSessionAdoptionSyncsBeforeAuthenticationCompletion() async {
        var steps: [String] = []

        await HubWebViewController.completeAuthenticationAfterAdoption(
            succeeded: true,
            syncAuthState: {
                steps.append("sync")
                return true
            },
            syncFailure: { steps.append("show-error") },
            completion: { steps.append("complete") }
        )

        #expect(steps == ["sync", "complete"])
    }

    @Test func authStateSyncFailureRequestsRetryableHubError() throws {
        let request = try #require(HubWebViewController.authenticationSyncFailureRequest())
        let arguments = try #require(
            try JSONSerialization.jsonObject(with: Data(request.arguments.utf8)) as? [String: String]
        )

        #expect(arguments == ["login_step": "error"])
        #expect(request.script == "rownd.requestSignIn(\(request.arguments))")
    }

    @Test func existingAccountHubAuthenticationEmitsCompletionDataOnlyAfterDismissalCompletes() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            await MainActor.run {
                RowndEventEmitter.resetForTests()
                Context.currentContext.eventListeners.removeAll()
                Context.currentContext.store.dispatch(SetClockSync(clockSyncState: .synced))
                Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(
                    accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
                )))
            }

            let message = try RowndHubInteropMessage.fromJson(message: #"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token","front_token":"front-token","user_type":"existing_user","app_variant_user_type":"existing_user"}}"#)
            guard case .authentication(let payload) = message.payload else {
                Issue.record("Expected authentication payload")
                return
            }

            let dismissal = await MainActor.run { HubDismissalProbe() }
            let eventHandler = RecordingRowndEventHandler()
            Rownd.addEventHandler(eventHandler)

            let completionTask = Task { @MainActor in
                await HubWebViewController.completeAuthentication(
                    store: Context.currentContext.store,
                    initialJsFunctionArgsAsJson: "{}",
                    currentJsFunctionArgsAsJson: { "{}" },
                    hideHub: dismissal.hide,
                    eventData: payload.signInCompletedEventData
                )
            }

            await dismissal.waitUntilStarted()
            #expect(eventHandler.events.isEmpty)
            await dismissal.complete()
            await completionTask.value

            let event = try #require(eventHandler.events.first)
            #expect(eventHandler.events.map(\.event) == [.signInCompleted])
            #expect(event.data?["user_type"]??.value as? String == "existing_user")
            #expect(event.data?["app_variant_user_type"]??.value as? String == "existing_user")
        }
    }

    @Test func authenticationCompletionKeepsHubOpenAfterNewerAPICall() async throws {
        try await withGlobalTestLock {
            var didHideHub = false
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            await MainActor.run {
                RowndEventEmitter.resetForTests()
                Context.currentContext.eventListeners.removeAll()
                Context.currentContext.store.dispatch(SetClockSync(clockSyncState: .synced))
                Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(
                    accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
                )))
            }

            let eventHandler = RecordingRowndEventHandler()
            Rownd.addEventHandler(eventHandler)

            await HubWebViewController.completeAuthentication(
                store: Context.currentContext.store,
                initialJsFunctionArgsAsJson: #"{"login_step":"init"}"#,
                currentJsFunctionArgsAsJson: { #"{"login_step":"verification"}"# },
                hideHub: { completion in
                    didHideHub = true
                    completion()
                }
            )

            #expect(!didHideHub)
            #expect(eventHandler.events.map(\.event) == [.signInCompleted])
        }
    }

    @Test func signInCompletedEventOnlyFiresOnceForSameAccessToken() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            await MainActor.run {
                RowndEventEmitter.resetForTests()
                Context.currentContext.eventListeners.removeAll()
                Context.currentContext.store.dispatch(SetClockSync(clockSyncState: .synced))
                Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(
                    accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
                )))
            }

            let eventHandler = RecordingRowndEventHandler()
            Rownd.addEventHandler(eventHandler)

            await HubWebViewController.completeAuthentication(
                store: Context.currentContext.store,
                initialJsFunctionArgsAsJson: "{}",
                currentJsFunctionArgsAsJson: { "{}" },
                hideHub: { completion in completion() }
            )

            await MainActor.run {
                RowndEventEmitter.emit(RowndEvent(event: .signInCompleted))
            }

            #expect(eventHandler.events.map(\.event) == [.signInCompleted])
        }
    }

    private func assertAuthenticationMessageDecodeFails(_ json: String) {
        do {
            _ = try RowndHubInteropMessage.fromJson(message: json)
            Issue.record("Expected authentication payload decode to fail")
        } catch {}
    }
}

private final class RecordingRowndEventHandler: RowndEventHandlerDelegate {
    private(set) var events: [RowndEvent] = []

    func handleRowndEvent(_ event: RowndEvent) {
        events.append(event)
    }
}

@MainActor private final class HubDismissalProbe {
    private var completion: (() -> Void)?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func hide(completion: @escaping () -> Void) {
        self.completion = completion
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func complete() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}
