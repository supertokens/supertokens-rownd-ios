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

    @Test func authenticationCompletionEmitsSignInCompletedEvent() async throws {
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
                hideHub: {}
            )

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
                hideHub: {}
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
