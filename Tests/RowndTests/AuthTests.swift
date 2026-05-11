//
//  AuthTests.swift
//  RowndTests
//
//  Created by Matt Hamann on 9/21/22.
//

import Foundation
import Mocker
import CryptoKit
import Factory
import Get
import ReSwiftThunk
import Combine
import JWTDecode
import Testing

@testable import Rownd

@Suite(.serialized) struct AuthTests {

    init() async throws {
        Container.tokenApi.register {
            APIClient.mock {
                $0.delegate = tokenApiConfig.delegate
            }
        }
        let store = Context.currentContext.store
        await MainActor.run {
            store.dispatch(SetClockSync(clockSyncState: .synced))
        }
        Mocker.removeAll()
    }
    
    @Test func testRefreshToken() async throws {
        let store = Context.currentContext.store

        Task { @MainActor in
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: NSDate().timeIntervalSince1970), // this will be expired
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        let responseData = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 1000).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )
        
        var mock = Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 200,
            data: [
                .post : try JSONEncoder().encode(responseData)
            ]
        )
        
        mock.onRequestHandler = OnRequestHandler(httpBodyType: [String:String].self) { request, postBodyArguments in
            print("Refresh called")
        }
        
        mock.register()

        let authState = try? await Context.currentContext.authenticator.refreshToken()

        #expect(authState != nil, "Returned resource should not be nil")
        #expect(authState?.accessToken != nil, "Access token should be present")
        #expect(authState?.accessToken == responseData.accessToken, "Access token should be updated")
    }
    
    @Test func testMultipleAuthenticatedReqeustsWithExpiredAccessToken() async throws {
        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -1000).timeIntervalSince1970), // this will be expired
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        let responseData = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 1000).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )
        print("Response data will be: \(String(describing: responseData))")
        
        var numTimesRefreshCalled = 0
        var mock = Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 200,
            data: [
                .post : try JSONEncoder().encode(responseData)
            ]
        )
        
        mock.onRequestHandler = OnRequestHandler(httpBodyType: [String:String].self) { request, postBodyArguments in
            numTimesRefreshCalled += 1
            print("Refresh called: \(numTimesRefreshCalled) times")
        }
        
        mock.delay = DispatchTimeInterval.seconds(2)
        
        mock.register()

        async let task1 = Rownd.getAccessToken()
        async let task2 = Rownd.getAccessToken()
        async let task3 = Rownd.getAccessToken()

        // Wait for all values concurrently
        let (value1, value2, value3) = try await (task1, task2, task3)

        // Ensure they all match the expected token
        #expect(value1 == responseData.accessToken)
        #expect(value2 == responseData.accessToken)
        #expect(value3 == responseData.accessToken)

        #expect(numTimesRefreshCalled == 1)
    }
    
    @Test func testRefreshTokenRetryWithHttpErrors() async throws {
        let store = Context.currentContext.store

        Task { @MainActor in
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -1000).timeIntervalSince1970), // this will be expired
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        let responseData = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 1000).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )
        print("Response data will be: \(String(describing: responseData))")
        
        var numTimesRefreshCalled = 0
        var mock = Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 500,
            data: [
                .post : try JSONEncoder().encode(["error": "Something went wrong"])
            ]
        )
        
        mock.onRequestHandler = OnRequestHandler(httpBodyType: [String:String].self) { request, postBodyArguments in
            // After a couple of errors, make the mock return normal status
            if numTimesRefreshCalled == 2 {
                do {
                    Mock(
                        url: URL(string: "https://api.rownd.io/hub/auth/token")!,
                        dataType: .json,
                        statusCode: 200,
                        data: [
                            .post : try JSONEncoder().encode(responseData)
                        ]
                    ).register()
                } catch {
                    Issue.record("Failed to register updated mock")
                }
            }
            
            numTimesRefreshCalled += 1
            print("Refresh called: \(numTimesRefreshCalled) times")
        }
        
        mock.delay = DispatchTimeInterval.seconds(2)
        
        mock.register()

        let token1 = try await Rownd.getAccessToken()
        #expect(token1 == responseData.accessToken)
    }
    
    @Test func testRefreshTokenThrowsWhenOfflineShouldNotSignOut() async throws {
        let store = Context.currentContext.store

        Task { @MainActor in
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -1000).timeIntervalSince1970), // this will be expired
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        let responseData = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 1000).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )
        
        Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 200,
            data: [
                .post : try JSONEncoder().encode(responseData)
            ],
            requestError: URLError(.notConnectedToInternet)
        ).register()

        do {
            let _ = try await Rownd.getAccessToken()
            Issue.record("Token refresh should have failed due to network conditions")
        } catch {
            #expect(store.state.auth.isAuthenticated == true)
        }
    }
    
    @Test func testSignOutWhenRefreshTokenIsAlreadyConsumed() async throws {
        Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 400,
            data: [
                .post : try JSONEncoder().encode([
                    "statusCode": "400",
                    "error":"Bad Request",
                    "message":"Invalid refresh token: Refresh token has been consumed"
                ])
            ]
        ).register()
        
        let accessToken = generateJwt(expires: Date.init(timeIntervalSinceNow: -1000).timeIntervalSince1970) // this will be expired
        let store = Context.currentContext.store
        
        let authSubscriber = TestFilteredSubscriber<AuthState?>()
        store.subscribe(authSubscriber) {
            $0.select { $0.auth }
        }

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: accessToken,
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        await Task { @MainActor in
            #expect((authSubscriber.receivedValue as? AuthState)?.isAuthenticated == true, "User should be authenticated initially")

            let accessToken2 = try? await Rownd.getAccessToken()
            #expect(accessToken2 == nil, "Returned token should be nil")

            #expect((authSubscriber.receivedValue as? AuthState)?.isAuthenticated == false, "User should no longer be authenticated")
        }.value
    }
    
    @Test func testRefreshTokenThrowsWhenHttpServerErrorsOccur() async throws {
        let store = Context.currentContext.store

        Task { @MainActor in
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -1000).timeIntervalSince1970), // this will be expired
                refreshToken: "eyJhbGciOiJFZERTQSIsImtpZCI6InNpZy0xNjQ0OTM3MzYwIn0.eyJqdGkiOiJiNzY4NmUxNC0zYjk2LTQzMTItOWM3ZS1iODdmOTlmYTAxMzIiLCJhdWQiOlsiYXBwOjMzNzA4MDg0OTIyMTU1MDY3MSJdLCJzdWIiOiJnb29nbGUtb2F1dGgyfDExNDg5NTEyMjc5NTQ1MjEyNzI3NiIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9hcHBfdXNlcl9pZCI6ImM5YTgxMDM5LTBjYmMtNDFkNy05YTlkLWVhOWI1YTE5Y2JmMCIsImh0dHBzOi8vYXV0aC5yb3duZC5pby9pc192ZXJpZmllZF91c2VyIjp0cnVlLCJpc3MiOiJodHRwczovL2FwaS5yb3duZC5pbyIsImlhdCI6MTY2NTk3MTk0MiwiaHR0cHM6Ly9hdXRoLnJvd25kLmlvL2p3dF90eXBlIjoicmVmcmVzaF90b2tlbiIsImV4cCI6MTY2ODU2Mzk0Mn0.Yn35j83bfFNgNk26gTvd4a2a2NAGXp7eknvOaFAtd3lWCdvtw6gKRso6Uzd7uydy2MWJFRWC38AkV6lMMfnrDw"
            )))
        }

        let responseData = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 1000).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )
        
        Mock(
            url: URL(string: "https://api.rownd.io/hub/auth/token")!,
            ignoreQuery: true,
            dataType: .json,
            statusCode: 504,
            data: [
                .post : try JSONEncoder().encode(responseData)
            ]
        ).register()

        do {
            let _ = try await Rownd.getAccessToken()
            Issue.record("Token refresh should have failed due to network conditions")
        } catch {
            #expect(store.state.auth.isAuthenticated == true)
        }
    }

    @Test func testAccessTokenValidWithMargin() async throws {
        let accessTokenNew = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessToken65secs = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 65).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessTokenOld = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessToken55secs = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 55).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        #expect(accessTokenNew.isAccessTokenValid == true)
        #expect(accessToken65secs.isAccessTokenValid == true)

        #expect(accessTokenOld.isAccessTokenValid == false)
        #expect(accessToken55secs.isAccessTokenValid == false)
    }

    @Test func alwaysThrowWhenAccessTokenCannotBeRetrieved() async throws {
        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
                refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
            )))
        }

        let authenticator = TestAuthenticator()
        Context.currentContext.authenticator = authenticator

        // Refresh token has already been used
        authenticator.refreshTokenBehavior = AuthenticationError
            .invalidRefreshToken(details: "Refresh token has been consumed")
        await #expect(
            throws: AuthenticationError.invalidRefreshToken(details: "Refresh token has been consumed")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: true)
        }

        authenticator.refreshTokenBehavior = AuthenticationError
            .networkConnectionFailure(details: "Network offline")
        await #expect(
            throws: AuthenticationError.networkConnectionFailure(details: "Network offline")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: true)
        }
    }

    @Test func onlyThrowWhenAccessTokenCannotBeRetrievedForNetworkReasons() async throws {
        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
                refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
            )))
        }

        let authenticator = TestAuthenticator()
        Context.currentContext.authenticator = authenticator

        // Refresh token has already been used
        authenticator.refreshTokenBehavior = AuthenticationError
            .invalidRefreshToken(details: "Refresh token has been consumed")
        #expect(try await store.state.auth.getAccessToken(throwIfMissing: false) == nil)

        // Network is down
        authenticator.refreshTokenBehavior = AuthenticationError
            .networkConnectionFailure(details: "Network offline")
        await #expect(
            throws: AuthenticationError.networkConnectionFailure(details: "Network offline")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: false)
        }
    }
}

struct Header: Encodable {
    let alg = "HS256"
    let typ = "JWT"
}

struct Payload: Encodable {
    var sub = "1234567890"
    var name = "John Doe"
    var iat = 1516239022
    var exp = Int(Date.init().timeIntervalSince1970)
}

internal func generateJwt(expires: TimeInterval) -> String {
    let secret = "your-256-bit-secret"
    let privateKey = SymmetricKey(data: Data(secret.utf8))
    
    let headerJSONData = try! JSONEncoder().encode(Header())
    let headerBase64String = headerJSONData.urlSafeBase64EncodedString()
    
    var payload = Payload()
    payload.exp = Int(expires)
    let payloadJSONData = try! JSONEncoder().encode(payload)
    let payloadBase64String = payloadJSONData.urlSafeBase64EncodedString()
    
    let toSign = Data((headerBase64String + "." + payloadBase64String).utf8)
    
    let signature = HMAC<SHA256>.authenticationCode(for: toSign, using: privateKey)
    let signatureBase64String = Data(signature).urlSafeBase64EncodedString()
    
    let token = [headerBase64String, payloadBase64String, signatureBase64String].joined(separator: ".")
    return token
}

extension Data {
    func urlSafeBase64EncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

class TestAuthenticator: AuthenticatorProtocol {

    public var refreshTokenBehavior: AuthenticationError?

    func getValidToken() async throws -> AuthState {
        return try await refreshToken()
    }

    func refreshToken() async throws -> AuthState {
        guard let refreshTokenBehavior = refreshTokenBehavior else {
            return AuthState()
        }

        throw refreshTokenBehavior
    }


}
