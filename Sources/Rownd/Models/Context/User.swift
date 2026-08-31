//
//  Auth.swift
//  framework
//
//  Created by Matt Hamann on 7/8/22.
//

import AnyCodable
import Foundation
import OSLog
import ReSwift
import ReSwiftThunk
import SuperTokensIOS
import UIKit

private let log = Logger(subsystem: "io.rownd.sdk", category: "user")

public typealias UserStateData = [String: AnyCodable]

public enum UserStateVal: String, Codable, Hashable {
    case enabled = "enabled"
    case disabled = "disabled"
}

public enum UserAuthLevel: String, Codable, Hashable {
    case instant = "instant"
    case guest = "guest"
    case unverified = "unverified"
    case verified = "verified"
    case unknown = "unknown"
}

public struct UserState: Hashable {
    public var isLoading: Bool = false
    public var isErrored: Bool = false
    public var errorMessage: String?
    public var data: UserStateData = [:]
    public var meta: UserStateData? = [:]
    public var state: UserStateVal = .enabled
    public var authLevel: UserAuthLevel = .unknown
    internal var activeSaveOperations: Set<UUID> = []
    internal var activeFetchOperations: Set<UUID> = []
}

extension UserState: Codable {
    public enum CodingKeys: String, CodingKey {
        case data, meta, state, isLoading
        case authLevel = "auth_level"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = try container.decode([String: AnyCodable].self, forKey: .data)
        self.meta = try container.decodeIfPresent([String: AnyCodable].self, forKey: .meta) ?? [:]
        self.isLoading = try container.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        self.state = try container.decodeIfPresent(UserStateVal.self, forKey: .state) ?? .enabled
        self.authLevel =
            try container.decodeIfPresent(UserAuthLevel.self, forKey: .authLevel) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(meta, forKey: .meta)
        try container.encode(isLoading, forKey: .isLoading)
        try container.encode(state, forKey: .state)
        try container.encode(authLevel, forKey: .authLevel)
    }

    public func get() -> UserState {
        return self
    }

    public func get(field: String) -> Any {
        return self.data[field] ?? nil
    }

    public func get<T>(field: String) -> T? {
        guard let value = self.data[field] else {
            return nil
        }

        return value.value as? T
    }

    public func set(data: [String: AnyCodable]) {
        DispatchQueue.main.async {
            Context.currentContext.store.dispatch(UserData.save(data))
        }
    }

    public func set(field: String, value: AnyCodable) {
        DispatchQueue.main.async {
            var optimisticData = Context.currentContext.store.state.user.data
            optimisticData[field] = value
            Context.currentContext.store.dispatch(
                UserData.save([field: value], optimisticData: optimisticData)
            )
        }
    }

    internal func setMetaData(_ meta: [String: AnyCodable]) {
        DispatchQueue.main.async {
            Context.currentContext.store.dispatch(UserData.saveMetaData(meta))
        }
    }

    internal func setMetaData(field: String, value: AnyCodable) {
        var meta = self.meta ?? [:]
        meta[field] = value
        DispatchQueue.main.async {
            Context.currentContext.store.dispatch(UserData.saveMetaData(meta))
        }
    }
}

struct SetUserFetchLoading: Action {
    var operationId: UUID
    var isLoading: Bool
}

struct SetUserData: Action {
    var data: [String: AnyCodable] = [:]
    var meta: [String: AnyCodable]? = [:]
}

struct SetUserError: Action {
    var isErrored: Bool = true
    var errorMessage: String
}

struct SetUserSaveLoading: Action {
    var operationId: UUID
    var isLoading: Bool
}

struct ReconcileUserData: Action {
    var expectedData: UserStateData
    var replacementData: UserStateData
}

struct SetUserState: Action {
    var payload: UserState
}

func userReducer(action: Action, state: UserState?) -> UserState {
    var state = state ?? UserState()

    switch action {
    case let action as SetUserState:
        let activeSaveOperations = state.activeSaveOperations
        let activeFetchOperations = state.activeFetchOperations
        state = action.payload
        state.activeSaveOperations = activeSaveOperations
        state.activeFetchOperations = activeFetchOperations
        state.isLoading = !activeSaveOperations.isEmpty || !activeFetchOperations.isEmpty
    case let action as SetUserData:
        state.data = action.data
        state.meta = action.meta ?? [:]
        state.isLoading = !state.activeSaveOperations.isEmpty || !state.activeFetchOperations.isEmpty
        state.isErrored = false
        state.errorMessage = nil
    case let action as ReconcileUserData:
        let affectedFields = Set(action.expectedData.keys).union(action.replacementData.keys)
        for field in affectedFields where state.data[field] == action.expectedData[field] {
            if let replacement = action.replacementData[field] {
                state.data[field] = replacement
            } else {
                state.data.removeValue(forKey: field)
            }
        }
    case let action as SetUserSaveLoading:
        if action.isLoading {
            state.activeSaveOperations.insert(action.operationId)
        } else {
            state.activeSaveOperations.remove(action.operationId)
        }
        state.isLoading = !state.activeSaveOperations.isEmpty || !state.activeFetchOperations.isEmpty
    case let action as SetUserFetchLoading:
        if action.isLoading {
            state.activeFetchOperations.insert(action.operationId)
        } else {
            state.activeFetchOperations.remove(action.operationId)
        }
        state.isLoading = !state.activeSaveOperations.isEmpty || !state.activeFetchOperations.isEmpty
    case let action as SetUserError:
        state.isErrored = action.isErrored
        state.errorMessage = action.errorMessage
    case let action as SetAuthState:
        if !action.payload.isAuthenticated {
            state = UserState()
        }
    default:
        break
    }

    return state
}

/* API / side-effecty things */

// Easily unwrap the main payload from the `app` key
struct UserDataPayload: Codable {
    var data: [String: AnyCodable]
}

struct UserMetaDataPayload: Codable {
    var meta: [String: AnyCodable]
}

public struct UserStateResponse: Hashable, Codable {
    public var data: UserStateData = [:]
    public var meta: UserStateData? = [:]
    public var state: UserStateVal = .enabled
    public var authLevel: UserAuthLevel = .unknown

    public enum CodingKeys: String, CodingKey {
        case data, meta, state
        case authLevel = "auth_level"
    }
}

public struct UserMetaDataResponse: Hashable {
    public var id: String = ""
    public var meta: [String: AnyCodable] = [:]
}

extension UserMetaDataResponse: Codable {
    public enum CodingKeys: String, CodingKey {
        case id, meta
    }
}

extension UserStateResponse {
    func toUserState() -> UserState {
        return UserState(
            data: data,
            meta: meta ?? [:],
            state: state,
            authLevel: authLevel
        )
    }
}

class UserData {
    internal enum FetchResult: Equatable {
        case profile(UserStateResponse)
        case notFound
    }

    internal enum ForegroundFetchOutcome: Equatable {
        case profileSynchronized
        case profileHydrationStillPending
        case signedOut
        case ignored
        case failed
    }

    internal static let fetchCoordinator = UserProfileFetchCoordinator()
    internal static let profileHydrationRetryCoordinator = ProfileHydrationRetryCoordinator()
    internal static var testingRequestSession: URLSession?
    internal static var testingExpectedSessionRequestSession: URLSession?

    private enum PluginRequestError: Error {
        case statusCode(Int)
        case nonHTTPResponse
    }

    private static func sendPluginRequest<Response: Decodable>(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Response? {
        var request = URLRequest(url: try SuperTokensPluginRoutes.url(path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await (testingRequestSession ?? URLSession.shared).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginRequestError.nonHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PluginRequestError.statusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func sendExpectedSessionPluginRequest<Response: Decodable>(
        path: String,
        method: String,
        body: Data,
        accessToken: String
    ) async throws -> Response? {
        var request = URLRequest(url: try SuperTokensPluginRoutes.url(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.setValue("anti-csrf", forHTTPHeaderField: "rid")

        let session: URLSession
        if let testingExpectedSessionRequestSession {
            session = testingExpectedSessionRequestSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = (configuration.protocolClasses ?? []).filter {
                $0 != SuperTokensURLProtocol.self
            }
            session = URLSession(configuration: configuration)
        }

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginRequestError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PluginRequestError.statusCode(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: responseData)
    }

    static func onReceiveUserData(_ action: SetUserData) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard getState() != nil else { return }
            DispatchQueue.main.async {
                dispatch(action)
            }
        }
    }

    internal static func fetchUserData(_ state: RowndState) async throws -> FetchResult {
        try await Task.retrying {
            try await retrieveUserData(state)
        }.value
    }

    internal static func fetchUserDataOnce(_ state: RowndState) async throws -> FetchResult {
        try Task.checkCancellation()
        return try await retrieveUserData(state)
    }

    internal static func fetchReplacementUserData(_ state: RowndState) async throws -> UserStateResponse? {
        switch try await fetchUserData(state) {
        case .profile(let profile): return profile
        case .notFound: return nil
        }
    }

    private static func retrieveUserData(_ state: RowndState) async throws -> FetchResult {
        guard state.auth.isAuthenticated else {
            throw RowndError("User must be authenticated before fetching profile")
        }

        do {
            let user: UserStateResponse? = try await sendPluginRequest(path: "/user", method: "GET")
            log.debug("Decoded user response: \(String(describing: user))")

            guard let user else {
                throw RowndError("Failed to load or decode user")
            }
            return .profile(user)
        } catch {
            log.error("Failed to retrieve user: \(String(describing: error))")

            if case .statusCode(let statusCode) = error as? PluginRequestError,
               statusCode == 404 {
                return .notFound
            }

            throw RowndError("Failed to retrieve user: \(error.localizedDescription)")
        }
    }

    static func fetch() -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }

            Task {
                let outcome = await fetchForegroundUserData(state)
                await scheduleProfileHydrationRetryIfPending(outcome)
            }
        }
    }

    @discardableResult
    internal static func fetchForegroundUserData(
        _ state: RowndState,
        fetchUserData: @escaping (RowndState) async throws -> FetchResult = UserData.fetchUserData,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() },
        commitIf: @escaping @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> ForegroundFetchOutcome {
        guard state.auth.isAuthenticated,
              let rowndAccessToken = state.auth.accessToken,
              let sessionIdentity = await SuperTokensSessionBridge.currentSessionIdentity(),
              SuperTokensSessionBridge.tokensBelongToSameSession(
                rowndAccessToken,
                sessionIdentity.accessToken
              ),
              let ticket = fetchCoordinator.begin(
                accessToken: sessionIdentity.accessToken,
                purpose: .foreground
              ) else {
            return .ignored
        }

        await MainActor.run {
            Context.currentContext.store.dispatch(SetUserFetchLoading(
                operationId: ticket.id,
                isLoading: true
            ))
        }

        let outcome = await withTaskCancellationHandler {
            await performForegroundFetch(
                sessionIdentity: sessionIdentity,
                ticket: ticket,
                fetchUserData: fetchUserData,
                persistState: persistState,
                commitIf: commitIf
            )
        } onCancel: {
            fetchCoordinator.cancel(ticket)
        }

        fetchCoordinator.finish(ticket)
        await MainActor.run {
            Context.currentContext.store.dispatch(SetUserFetchLoading(
                operationId: ticket.id,
                isLoading: false
            ))
        }
        return outcome
    }

    internal static func scheduleProfileHydrationRetry(
        for identity: SuperTokensSessionBridge.StableSessionIdentity,
        coordinator: ProfileHydrationRetryCoordinator = profileHydrationRetryCoordinator,
        appIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        fetchUserData: @escaping (RowndState) async throws -> FetchResult = UserData.fetchUserDataOnce,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
    ) async {
        await coordinator.schedule(for: identity) { identity in
            guard let state = await MainActor.run(body: { () -> RowndState? in
                let store = Context.currentContext.store
                guard appIsActive(),
                      store.state.auth.profileHydrationPendingSessionIdentity == identity,
                      store.state.auth.accessToken.flatMap(
                        SuperTokensSessionBridge.stableSessionIdentity
                      ) == identity else {
                    return nil
                }
                return store.state
            }),
            let currentSession = await SuperTokensSessionBridge.currentSessionIdentity(),
            currentSession.stable == identity else {
                return .stop
            }

            switch await fetchForegroundUserData(
                state,
                fetchUserData: fetchUserData,
                persistState: persistState,
                commitIf: {
                    !Task.isCancelled
                        && appIsActive()
                        && Context.currentContext.store.state.auth
                            .profileHydrationPendingSessionIdentity == identity
                }
            ) {
            case .profileSynchronized, .signedOut:
                return .stop
            case .profileHydrationStillPending, .ignored, .failed:
                return .retry
            }
        }
    }

    internal static func scheduleProfileHydrationRetryIfPending(
        _ outcome: ForegroundFetchOutcome,
        coordinator: ProfileHydrationRetryCoordinator = profileHydrationRetryCoordinator,
        appIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        fetchUserData: @escaping (RowndState) async throws -> FetchResult = UserData.fetchUserDataOnce,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
    ) async {
        guard outcome == .profileHydrationStillPending || outcome == .failed,
              let identity = await MainActor.run(body: { () -> SuperTokensSessionBridge.StableSessionIdentity? in
                let auth = Context.currentContext.store.state.auth
                guard let identity = auth.profileHydrationPendingSessionIdentity,
                      auth.accessToken.flatMap(SuperTokensSessionBridge.stableSessionIdentity)
                        == identity else {
                    return nil
                }
                return identity
              }),
              await SuperTokensSessionBridge.currentSessionIdentity()?.stable == identity else {
            return
        }
        await scheduleProfileHydrationRetry(
            for: identity,
            coordinator: coordinator,
            appIsActive: appIsActive,
            fetchUserData: fetchUserData,
            persistState: persistState
        )
    }

    private static func performForegroundFetch(
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        fetchUserData: @escaping (RowndState) async throws -> FetchResult,
        persistState: @escaping @MainActor (RowndState) -> Bool,
        commitIf: @escaping @MainActor () -> Bool
    ) async -> ForegroundFetchOutcome {
        do {
            guard await MainActor.run(body: commitIf) else { return .ignored }
            let synchronized = try await synchronizeForegroundSession(
                sessionIdentity,
                ticket: ticket,
                persistState: persistState,
                commitIf: commitIf
            )
            let result = try await fetchUserData(synchronized.state)
            try Task.checkCancellation()
            guard await MainActor.run(body: commitIf) else { return .ignored }
            let current = try await synchronizeForegroundSession(
                sessionIdentity,
                ticket: ticket,
                persistState: persistState,
                commitIf: commitIf
            ).identity

            guard await SuperTokensSessionBridge.isCurrentSession(current),
                  fetchCoordinator.isCurrent(ticket) else {
                return .ignored
            }

            switch result {
            case .notFound:
                let retainsPendingHydration = await MainActor.run { () -> Bool? in
                    let auth = Context.currentContext.store.state.auth
                    guard commitIf(),
                          fetchCoordinator.isCurrent(ticket),
                          SuperTokensSessionBridge.tokensBelongToSameSession(
                            auth.accessToken,
                            current.accessToken
                          ) else {
                        return nil
                    }
                    return auth.profileHydrationPendingSessionIdentity == current.stable
                }
                guard let retainsPendingHydration else { return .ignored }
                if retainsPendingHydration {
                    log.warning("The user profile is still unavailable; retaining its session for a later retry.")
                    return .profileHydrationStillPending
                }

                let didSignOut = await SuperTokensSessionBridge.signOutIfCurrentSession(
                    current,
                    expectedRowndAccessToken: current.accessToken,
                    condition: { fetchCoordinator.isCurrent(ticket) }
                )
                if didSignOut {
                    log.warning("This user was not found (likely deleted), so they were signed out.")
                    return .signedOut
                }
                return .ignored
            case .profile(let userResponse):
                let didCommit = await MainActor.run {
                    let store = Context.currentContext.store
                    guard let state = store.state,
                          commitIf(),
                          fetchCoordinator.isCurrent(ticket),
                          SuperTokensSessionBridge.tokensBelongToSameSession(
                            state.auth.accessToken,
                            current.accessToken
                          ) else {
                        return false
                    }

                    var auth = state.auth
                    let clearedPendingHydration =
                        auth.profileHydrationPendingSessionIdentity == current.stable
                    if clearedPendingHydration {
                        auth.profileHydrationPendingSessionIdentity = nil
                    }
                    let user = userResponse.toUserState()
                    var candidate = state
                    candidate.auth = auth
                    candidate.user = user
                    guard persistState(candidate) else { return false }
                    if clearedPendingHydration {
                        store.dispatch(SetAuthState(payload: auth))
                    }
                    store.dispatch(SetUserState(payload: user))
                    return true
                }
                guard didCommit else { return .failed }

                guard await SuperTokensSessionBridge.isCurrentSession(current),
                      fetchCoordinator.isCurrent(ticket) else {
                    await MainActor.run {
                        let store = Context.currentContext.store
                        guard let state = store.state,
                              commitIf(),
                              fetchCoordinator.isCurrent(ticket),
                              SuperTokensSessionBridge.tokensBelongToSameSession(
                                state.auth.accessToken,
                                current.accessToken
                              ) else {
                            return
                        }
                        var candidate = state
                        candidate.user = UserState()
                        guard persistState(candidate) else { return }
                        store.dispatch(SetUserState(payload: UserState()))
                    }
                    return .ignored
                }
                return .profileSynchronized
            }
        } catch {
            if Task.isCancelled { return .ignored }
            guard await MainActor.run(body: commitIf) else { return .ignored }
            log.error(
                "Something went wrong while fetching the user's profile \(String(describing: error))"
            )
            return .failed
        }
    }

    private static func synchronizeForegroundSession(
        _ sessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        persistState: @escaping @MainActor (RowndState) -> Bool,
        commitIf: @escaping @MainActor () -> Bool
    ) async throws -> (
        identity: SuperTokensSessionBridge.SessionIdentity,
        state: RowndState
    ) {
        for _ in 0..<4 {
            guard let currentIdentity = await SuperTokensSessionBridge.currentTokenVersion(
                of: sessionIdentity
            ), fetchCoordinator.isCurrent(ticket) else {
                throw RowndError("Foreground user profile fetch was superseded")
            }

            let synchronizedState = await MainActor.run { () -> RowndState? in
                let store = Context.currentContext.store
                guard let state = store.state,
                      commitIf(),
                      fetchCoordinator.isCurrent(ticket),
                      SuperTokensSessionBridge.tokensBelongToSameSession(
                        state.auth.accessToken,
                        currentIdentity.accessToken
                      ) else {
                    return nil
                }

                var auth = state.auth
                let shouldClearStaleMarker = auth.profileHydrationPendingSessionIdentity != nil
                    && auth.profileHydrationPendingSessionIdentity != currentIdentity.stable
                let shouldSynchronizeToken = auth.accessToken != currentIdentity.accessToken
                guard shouldClearStaleMarker || shouldSynchronizeToken else {
                    return state
                }

                if shouldClearStaleMarker {
                    auth.profileHydrationPendingSessionIdentity = nil
                }
                auth.accessToken = currentIdentity.accessToken
                auth.refreshToken = nil
                var candidate = state
                candidate.auth = auth
                guard persistState(candidate) else { return nil }
                store.dispatch(SetAuthState(payload: auth))
                return candidate
            }
            guard let synchronizedState,
                  let verifiedIdentity = await SuperTokensSessionBridge.currentTokenVersion(
                    of: sessionIdentity
                  ) else {
                throw RowndError("Foreground user profile session could not be synchronized")
            }
            if verifiedIdentity.accessToken == currentIdentity.accessToken {
                return (currentIdentity, synchronizedState)
            }
        }
        throw RowndError("Foreground user profile session did not stabilize")
    }

    static func save() -> Thunk<RowndState> {
        return save(Context.currentContext.store.state.user.data)
    }

    @discardableResult
    internal static func saveExpectedSession(
        _ data: [String: AnyCodable],
        expectedData: [String: AnyCodable],
        expectedSessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        beforeRequest: () async -> Void = {}
    ) async -> Bool {
        await beforeRequest()
        guard let requestIdentity = await SuperTokensSessionBridge.currentTokenVersion(
            of: expectedSessionIdentity
        ), fetchCoordinator.isCurrent(ticket) else {
            return false
        }

        let rowndSessionIsCurrent = await MainActor.run {
            fetchCoordinator.isCurrent(ticket)
                && SuperTokensSessionBridge.tokensBelongToSameSession(
                    Context.currentContext.store.state.auth.accessToken,
                    requestIdentity.accessToken
                )
        }
        guard rowndSessionIsCurrent else { return false }

        do {
            let user: UserStateResponse? = try await sendExpectedSessionPluginRequest(
                path: "/user",
                method: "PUT",
                body: JSONEncoder().encode(UserDataPayload(data: data)),
                accessToken: requestIdentity.accessToken
            )
            guard let user,
                  await SuperTokensSessionBridge.currentTokenVersion(
                    of: expectedSessionIdentity
                  ) != nil,
                  fetchCoordinator.isCurrent(ticket) else {
                return false
            }

            return await MainActor.run {
                let store = Context.currentContext.store
                guard fetchCoordinator.isCurrent(ticket),
                      SuperTokensSessionBridge.tokensBelongToSameSession(
                        store.state.auth.accessToken,
                        expectedSessionIdentity.accessToken
                      ) else {
                    return false
                }
                store.dispatch(ReconcileUserData(
                    expectedData: expectedData,
                    replacementData: user.data
                ))
                return true
            }
        } catch {
            logger.error("Failed to save expected-session user profile: \(String(describing: error))")
            return false
        }
    }

    static func save(
        _ data: [String: AnyCodable],
        optimisticData: [String: AnyCodable]? = nil
    ) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            let startSave = {
                guard let state = getState(), state.auth.isAuthenticated else { return }

                let previousData = state.user.data
                let expectedData = optimisticData ?? data
                let operationId = UUID()
                dispatch(SetUserData(data: expectedData, meta: state.user.meta))
                dispatch(SetUserSaveLoading(operationId: operationId, isLoading: true))

                Task {
                    defer {
                        DispatchQueue.main.async {
                            dispatch(SetUserSaveLoading(operationId: operationId, isLoading: false))
                        }
                    }

                    let userDataPayload = UserDataPayload(data: data)

                    do {
                        let user: UserStateResponse? = try await sendPluginRequest(
                            path: "/user",
                            method: "PUT",
                            body: JSONEncoder().encode(userDataPayload)
                        )

                        logger.debug("Decoded user response: \(String(describing: user))")

                        DispatchQueue.main.async {
                            dispatch(
                                ReconcileUserData(
                                    expectedData: expectedData,
                                    replacementData: user?.data ?? [:]
                                ))
                        }
                    } catch {
                        logger.error("Failed to save user profile: \(String(describing: error))")
                        DispatchQueue.main.async {
                            dispatch(
                                ReconcileUserData(
                                    expectedData: expectedData,
                                    replacementData: previousData
                                ))
                            dispatch(
                                SetUserError(
                                    errorMessage:
                                        "The user profile could not be saved: \(String(describing: error))"
                                ))
                        }
                    }
                }
            }

            if Thread.isMainThread {
                startSave()
            } else {
                DispatchQueue.main.async(execute: startSave)
            }
        }
    }

    static func saveMetaData(_ meta: [String: AnyCodable]) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }
            guard !state.user.isLoading else { return }

            DispatchQueue.main.async {
                dispatch(SetUserData(data: state.user.data, meta: meta))
            }

            Task {
                guard state.auth.isAuthenticated else {
                    return
                }

                do {
                    let response: UserMetaDataResponse? = try await sendPluginRequest(
                        path: "/user/meta",
                        method: "PUT",
                        body: JSONEncoder().encode(UserMetaDataPayload(meta: meta))
                    )

                    logger.debug("Saved Rownd meta data: \(String(describing: response))")
                } catch {
                    logger.error("Failed to save meta data: \(String(describing: error))")
                }
            }
        }
    }
}
