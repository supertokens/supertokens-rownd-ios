import Testing

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

    private func assertAuthenticationMessageDecodeFails(_ json: String) {
        do {
            _ = try RowndHubInteropMessage.fromJson(message: json)
            Issue.record("Expected authentication payload decode to fail")
        } catch {}
    }
}
