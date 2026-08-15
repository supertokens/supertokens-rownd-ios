//
//  AutomationTests.swift
//
//
//  Created by Michael Murray on 8/19/24.
//

import AnyCodable
import ReSwift
import XCTest

@testable import Rownd

final class UserTests: XCTestCase {
    
    let userStringWithIsLoading = """
    {\"meta\":{},\"data\":{},\"isLoading\":false}
    """

    func testDecodingUserWithIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }
    
    
    let userStringWithoutIsLoading = """
        {\"meta\":{},\"data\":{}}
    """

    func testDecodingUserWithoutIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithoutIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }
    
    let userStringWithDataAndWithoutIsLoading = """
        {\"data\":{\"user_id\":\"user_totlsniyvtakfd1y1cad6zpe\",\"anonymous_id\":\"anon_30df55f5-9567-4d5c-bc2e-2c277c075a30\"},\"meta\":{\"first_sign_in_method\":\"anonymous\",\"first_sign_in\":\"2024-10-15T19:46:13.985Z\",\"modified\":\"2024-10-15T19:46:13.141Z\",\"last_sign_in\":\"2024-10-15T19:46:13.985Z\",\"app_variants\":{\"base\":{\"last_sign_in_method\":\"anonymous\",\"last_sign_in\":\"2024-10-15T19:46:13.985Z\"}},\"auth_level\":\"guest\",\"last_sign_in_method\":\"anonymous\",\"created\":\"2024-10-15T19:46:13.141Z\",\"last_active\":\"2024-10-15T19:46:13.985Z\",\"verified_date\":\"2024-10-15T19:46:13.985Z\"}}
    """

    func testDecodingUserWithDataWithoutIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithDataAndWithoutIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            XCTAssertTrue(userState.data["user_id"] == "user_totlsniyvtakfd1y1cad6zpe")
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }

    func testRejectedEmailSaveRollsBackWithoutOverwritingANewerFieldEdit() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let originalConfig = Rownd.config
            defer {
                Context.currentContext = originalContext
                Rownd.config = originalConfig
                UserData.testingRequestSession = nil
                UserSaveURLProtocol.reset()
            }

            let store = createStore()
            var config = RowndConfig()
            config.supertokens = RowndSuperTokensConfig(
                appName: "User save tests",
                apiDomain: "https://auth.example.com"
            )
            Rownd.config = config
            UserSaveURLProtocol.configure(response: .statusCode(409), waitForRelease: true)
            UserData.testingRequestSession = makeUserSaveTestSession()

            await MainActor.run {
                _ = Context(store)
                store.dispatch(SetAuthState(payload: AuthState(accessToken: "access-token")))
                store.dispatch(
                    SetUserState(
                        payload: UserState(
                            data: [
                                "email": AnyCodable("before@example.com"),
                                "first_name": AnyCodable("Before"),
                            ]
                        )
                    )
                )
                store.state.user.set(field: "email", value: AnyCodable("rejected@example.com"))
            }

            try await waitForUserSaveRequest()

            await MainActor.run {
                XCTAssertEqual(
                    store.state.user.data["email"]?.value as? String,
                    "rejected@example.com"
                )

                var newerData = store.state.user.data
                newerData["first_name"] = AnyCodable("Newer edit")
                store.dispatch(SetUserData(data: newerData, meta: store.state.user.meta))
            }

            UserSaveURLProtocol.releaseResponse()
            try await waitForUserSaveToFail(store: store)

            await MainActor.run {
                XCTAssertEqual(
                    store.state.user.data["email"]?.value as? String,
                    "before@example.com"
                )
                XCTAssertEqual(
                    store.state.user.data["first_name"]?.value as? String,
                    "Newer edit"
                )
            }
        }
    }

    func testRejectedOrdinaryFieldSaveRollsBackForHTTPAndNetworkFailures() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let originalConfig = Rownd.config
            defer {
                Context.currentContext = originalContext
                Rownd.config = originalConfig
                UserData.testingRequestSession = nil
                UserSaveURLProtocol.reset()
            }

            let store = createStore()
            var config = RowndConfig()
            config.supertokens = RowndSuperTokensConfig(
                appName: "User save tests",
                apiDomain: "https://auth.example.com"
            )
            Rownd.config = config
            UserData.testingRequestSession = makeUserSaveTestSession()

            await MainActor.run {
                _ = Context(store)
                store.dispatch(SetAuthState(payload: AuthState(accessToken: "access-token")))
            }

            for response in [UserSaveTestResponse.statusCode(403), .networkFailure] {
                UserSaveURLProtocol.configure(response: response)
                await MainActor.run {
                    store.dispatch(
                        SetUserState(
                            payload: UserState(
                                data: [
                                    "email": AnyCodable("person@example.com"),
                                    "first_name": AnyCodable("Before"),
                                ]
                            )
                        )
                    )
                    store.state.user.set(field: "first_name", value: AnyCodable("Rejected"))
                }

                try await waitForUserSaveToFail(store: store)

                await MainActor.run {
                    XCTAssertEqual(
                        store.state.user.data["first_name"]?.value as? String,
                        "Before"
                    )
                    XCTAssertEqual(
                        store.state.user.data["email"]?.value as? String,
                        "person@example.com"
                    )
                }
            }
        }
    }
    
}

private enum UserSaveTestResponse {
    case statusCode(Int)
    case networkFailure
}

private final class UserSaveURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: UserSaveTestResponse = .statusCode(500)
    private static var responseGate: DispatchSemaphore?
    private static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/user"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let configuration = Self.currentConfiguration()
        let completeRequest = { [self] in
            switch configuration.response {
            case .statusCode(let statusCode):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .networkFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
        }

        guard let gate = configuration.gate else {
            completeRequest()
            return
        }

        DispatchQueue.global().async {
            gate.wait()
            completeRequest()
        }
    }

    override func stopLoading() {}

    static func configure(response: UserSaveTestResponse, waitForRelease: Bool = false) {
        lock.lock()
        self.response = response
        responseGate = waitForRelease ? DispatchSemaphore(value: 0) : nil
        requestCount = 0
        lock.unlock()
    }

    static func releaseResponse() {
        lock.lock()
        let gate = responseGate
        responseGate = nil
        lock.unlock()
        gate?.signal()
    }

    static func hasReceivedRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestCount > 0
    }

    static func reset() {
        lock.lock()
        let gate = responseGate
        responseGate = nil
        requestCount = 0
        response = .statusCode(500)
        lock.unlock()
        gate?.signal()
    }

    private static func currentConfiguration() -> (
        response: UserSaveTestResponse,
        gate: DispatchSemaphore?
    ) {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return (response, responseGate)
    }
}

private func makeUserSaveTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UserSaveURLProtocol.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}

private func waitForUserSaveRequest() async throws {
    for _ in 0..<100 {
        if UserSaveURLProtocol.hasReceivedRequest() {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw UserSaveTestError.timedOut
}

private func waitForUserSaveToFail(store: Store<RowndState>) async throws {
    for _ in 0..<100 {
        let receivedRequest = UserSaveURLProtocol.hasReceivedRequest()
        let didFail = await MainActor.run { store.state.user.isErrored && !store.state.user.isLoading }
        if receivedRequest && didFail {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw UserSaveTestError.timedOut
}

private enum UserSaveTestError: Error {
    case timedOut
}
