import Testing

@testable import Rownd

@Suite(.serialized) struct RowndHubInteropMessageTests {
    @Test func authenticationMessageAllowsNullRefreshToken() throws {
        let message = try RowndHubInteropMessage.fromJson(message: #"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":null}}"#)

        guard case .authentication(let payload) = message.payload else {
            Issue.record("Expected authentication payload")
            return
        }

        #expect(payload.accessToken == "access-token")
        #expect(payload.refreshToken == nil)
    }

    @Test func authenticationMessageDecodesAntiCSRF() throws {
        let message = try RowndHubInteropMessage.fromJson(message: #"{"type":"authentication","payload":{"access_token":"access-token","refresh_token":"refresh-token","anti_csrf":"anti-csrf-token"}}"#)

        guard case .authentication(let payload) = message.payload else {
            Issue.record("Expected authentication payload")
            return
        }

        #expect(payload.accessToken == "access-token")
        #expect(payload.refreshToken == "refresh-token")
        #expect(payload.antiCSRF == "anti-csrf-token")
    }
}
