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
        var userData = self.data
        userData[field] = value
        DispatchQueue.main.async {
            Context.currentContext.store.dispatch(UserData.save(userData))
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

struct SetUserLoading: Action {
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

struct SetUserState: Action {
    var payload: UserState
}

func userReducer(action: Action, state: UserState?) -> UserState {
    var state = state ?? UserState()

    switch action {
    case let action as SetUserState:
        state = action.payload
    case let action as SetUserData:
        state.data = action.data
        state.meta = action.meta ?? [:]
        state.isLoading = false
    case let action as SetUserLoading:
        state.isLoading = action.isLoading
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
    private static var fetchTask: Task<UserStateResponse?, Error>?

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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginRequestError.nonHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PluginRequestError.statusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func onReceiveUserData(_ action: SetUserData) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard getState() != nil else { return }
            DispatchQueue.main.async {
                dispatch(action)
            }
        }
    }

    internal static func fetchUserData(_ state: RowndState) async throws -> UserStateResponse? {
        if let handle = fetchTask {
            log.debug("User data fetch is already in progress")
            return try await handle.value
        }

        let task = Task.retrying { () throws -> UserStateResponse? in

            guard state.auth.isAuthenticated else {
                throw RowndError("User must be authenticated before fetching profile")
            }

            defer {
                fetchTask = nil
            }

            do {
                let user: UserStateResponse? = try await sendPluginRequest(path: "/user", method: "GET")

                log.debug("Decoded user response: \(String(describing: user))")

                guard let user = user else {
                    throw RowndError("Failed to load or decode user")
                }

                return user
            } catch {
                log.error("Failed to retrieve user: \(String(describing: error))")

                // If the user doesn't exist, sign out (user may have been deleted)
                if case .statusCode(let statusCode) = error as? PluginRequestError,
                    statusCode == 404
                {
                    log.warning(
                        "This user was not found (likely deleted), so they will be signed out.")
                    Rownd.signOut()
                    return nil
                }

                throw RowndError(
                    "Failed to retireve user: \(error.localizedDescription)"
                )
            }
        }

        self.fetchTask = task

        return try await task.value
    }

    static func fetch() -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }

            Task {
                guard state.auth.isAuthenticated else {
                    return
                }

                DispatchQueue.main.async {
                    dispatch(SetUserLoading(isLoading: true))
                }

                defer {
                    DispatchQueue.main.async {
                        dispatch(SetUserLoading(isLoading: false))
                    }
                }

                do {
                    let userResponse = try await fetchUserData(state)

                    guard let userResponse = userResponse else {
                        return
                    }

                    Task { @MainActor in
                        dispatch(
                            SetUserState(
                                payload: userResponse.toUserState()
                            ))
                    }
                } catch {
                    log.error(
                        "Something went wrong while fetching the user's profile \(String(describing: error))"
                    )
                }
            }
        }
    }

    static func save() -> Thunk<RowndState> {
        return save(Context.currentContext.store.state.user.data)
    }

    static func save(_ data: [String: AnyCodable]) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }
            guard !state.user.isLoading else { return }

            DispatchQueue.main.async {
                dispatch(SetUserData(data: data, meta: state.user.meta))
            }

            Task {
                guard state.auth.isAuthenticated else {
                    return
                }

                DispatchQueue.main.async {
                    dispatch(SetUserLoading(isLoading: true))
                }

                defer {
                    DispatchQueue.main.async {
                        dispatch(SetUserLoading(isLoading: false))
                    }
                }

                // Handle data that should be encrypted
                var updatedUserState = UserState()
                updatedUserState.data = data

                let userDataPayload = UserDataPayload(data: data)

                do {
                    let user: UserStateResponse? = try await sendPluginRequest(
                        path: "/user",
                        method: "PUT",
                        body: JSONEncoder().encode(userDataPayload)
                    )

                    logger.debug("Decoded user response: \(String(describing: user))")

                    DispatchQueue.main.async {
                        dispatch(SetUserData(data: user?.data ?? [:], meta: state.user.meta))
                    }
                } catch {
                    logger.error("Failed to save user profile: \(String(describing: error))")
                    DispatchQueue.main.async {
                        dispatch(
                            SetUserError(
                                errorMessage:
                                    "The user profile could not be saved: \(String(describing: error))"
                            ))
                    }
                }
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
