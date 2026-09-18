import Foundation
import Testing
@testable import Rownd

struct AccessTokenDecoderTests {
    private func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func preservesSessionClaims() throws {
        let token = "\(encode(#"{"alg":"RS256"}"#)).\(encode(#"{"sessionHandle":"session","sub":"user","tId":"tenant"}"#)).signature"
        let identity = try #require(SuperTokensSessionBridge.stableSessionIdentity(from: token))
        #expect(identity.sessionHandle == "session")
        #expect(identity.userId == "user")
        #expect(identity.tenantId == "tenant")
    }

    @Test(arguments: ["", "abc", "abc.def", "a.b.c.d", "..", "e30.A.sig", "e30.e3!0.sig"])
    func rejectsMalformedTokens(_ token: String) {
        #expect(AccessTokenDecoder.decode(token) == nil)
        #expect(SuperTokensSessionBridge.stableSessionIdentity(from: token) == nil)
        #expect(!SuperTokensSessionBridge.tokensBelongToSameSession(token, token))
    }

    @Test(arguments: ["", "{", "[]", "null", "true", "42", #""text""#, #"{"x":"\ud800"}"#])
    func rejectsInvalidHeaderOrPayload(_ json: String) {
        let invalidPart = encode(json)
        #expect(AccessTokenDecoder.decode("\(invalidPart).e30.sig") == nil)
        #expect(AccessTokenDecoder.decode("e30.\(invalidPart).sig") == nil)
    }

    @Test func acceptsPaddedSegmentsAndEmptySignature() {
        let token = "e30=.e30=."
        #expect(AccessTokenDecoder.decode(token) != nil)
    }
}
