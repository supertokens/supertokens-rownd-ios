import Foundation
import Testing

@testable import Rownd

@Suite struct HubMessageAuthorizationTests {
    private let trustedURL = URL(string: "https://hub.example.com/mobile_app")!
    private let sensitiveMessages: [(MessageType, String)] = [
        (.authentication, #"{"type":"authentication","payload":{"access_token":"forged","refresh_token":"forged","front_token":"forged"}}"#),
        (.signOut, #"{"type":"sign_out","payload":{"was_user_initiated":true}}"#),
        (.authChallengeInitiated, #"{"type":"auth_challenge_initiated","payload":{"challenge_id":"forged","user_identifier":"attacker@example.com"}}"#),
        (.authChallengeCleared, #"{"type":"auth_challenge_cleared"}"#),
        (.triggerSignInWithApple, #"{"type":"trigger_sign_in_with_apple","payload":{}}"#),
        (.triggerSignInWithGoogle, #"{"type":"trigger_sign_in_with_google","payload":{}}"#),
        (.userDataUpdate, #"{"type":"user_data_update","payload":{"data":{"admin":true}}}"#)
    ]

    @Test func sensitiveMessagesFromUntrustedOriginAreRejected() throws {
        for (messageType, json) in sensitiveMessages {
            #expect(try RowndHubInteropMessage.fromJson(message: json).type == messageType)
            let authorized = HubWebViewController.canHandleHubMessage(
                messageWebViewMatches: true,
                isMainFrame: true,
                securityOriginProtocol: "https",
                securityOriginHost: "attacker.example.com",
                securityOriginPort: 443,
                sourceURL: trustedURL,
                currentURL: trustedURL,
                baseURL: "https://hub.example.com"
            )

            #expect(!authorized, "Forged \(messageType) message must be rejected")
        }
    }

    @Test func sensitiveMessagesFromNonMainFrameAreRejected() throws {
        for (messageType, json) in sensitiveMessages {
            #expect(try RowndHubInteropMessage.fromJson(message: json).type == messageType)
            let authorized = HubWebViewController.canHandleHubMessage(
                messageWebViewMatches: true,
                isMainFrame: false,
                securityOriginProtocol: "https",
                securityOriginHost: "hub.example.com",
                securityOriginPort: 443,
                sourceURL: trustedURL,
                currentURL: trustedURL,
                baseURL: "https://hub.example.com"
            )

            #expect(!authorized, "Non-main-frame \(messageType) message must be rejected")
        }
    }

    @Test func trustedMainFrameIsAuthorized() {
        #expect(HubWebViewController.canHandleHubMessage(
            messageWebViewMatches: true,
            isMainFrame: true,
            securityOriginProtocol: "https",
            securityOriginHost: "hub.example.com",
            securityOriginPort: 443,
            sourceURL: trustedURL,
            currentURL: trustedURL,
            baseURL: "https://hub.example.com"
        ))
    }
}
