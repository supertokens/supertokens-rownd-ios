//
//  AppleSignUpCoordinator.swift
//  appleSignIn
//
//  Created by Michael Murray on 7/17/22.
//

import SwiftUI
import AuthenticationServices
import UIKit
import AnyCodable
import ReSwiftThunk
import Combine

private let appleSignInDataKey = "userAppleSignInData"

struct AppleSignInData: Codable {
    var email: String
    var firstName: String?
    var lastName: String?
    var fullName: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email = "email"
        case fullName = "full_name"
    }

    func toDictionary() -> Dictionary<String, AnyCodable> {
        var dictionary: Dictionary<String, AnyCodable> = [
            "email": AnyCodable(email)
        ]
        if let firstName = firstName {
            dictionary["first_name"] = AnyCodable(firstName)
        }
        if let lastName = lastName {
            dictionary["last_name"] = AnyCodable(lastName)
        }
        if let fullName = fullName {
            dictionary["full_name"] = AnyCodable(fullName)
        }
        return dictionary
    }
}

class AppleSignUpCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let operationLock = NSLock()
    private var currentOperationID: UUID?
    private var completionTask: Task<Void, Never>?
    private var currentHubRequestID: UUID?
    private var authorizationOperations: [ObjectIdentifier: UUID] = [:]
    var parent: Rownd?
    var intent: RowndSignInIntent?
    var cancellables = Set<AnyCancellable>()
    var signInWithApple: (String, String) async throws -> SuperTokensThirdPartySignInResponse
    var fetchAppConfig: () async -> AppConfigResponse? = {
        await AppConfig.fetch()
    }
    var syncAuthState: () async -> Bool = {
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
    }
    var waitBeforeCompletion: () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(2 * Double(NSEC_PER_SEC)))
    }
    var beforeHubPresentation: () async -> Void = {}
    var dismissHub: (UUID) async -> Void = { requestID in
        await Rownd.dismissHub(requestID: requestID)
    }
    var emitEvent: (RowndEvent) async -> Void = { event in
        await MainActor.run {
            RowndEventEmitter.emit(event)
        }
    }

    init(_ parent: Rownd, signInClient: SuperTokensThirdPartySignInClient = SuperTokensThirdPartySignInClient()) {
        self.parent = parent
        self.signInWithApple = { authorizationCode, clientType in
            try await signInClient.signInWithApple(
                authorizationCode: authorizationCode,
                clientType: clientType
            )
        }
        super.init()
    }

    func signIn(_ intent: RowndSignInIntent?) {
        self.intent = intent
        // Create an object of the ASAuthorizationAppleIDProvider
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        // Create a request
        let request = appleIDProvider.createRequest()
        // Define the scope of the request
        request.requestedScopes = [.fullName, .email]
        // Make the request
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])

        // Assigning the delegates
        authorizationController.presentationContextProvider = self
        authorizationController.delegate = self
        registerAuthorizationOperation(controllerID: ObjectIdentifier(authorizationController))
        authorizationController.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let vc = UIApplication.shared.windows.last?.rootViewController
        return (vc?.view.window!)!
    }

    private func getFullName(firstName: String?, lastName: String?) -> String {
        return String("\(firstName ?? "") \(lastName ?? "")")
    }

    // If authorization is successful then this method will get triggered
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let operationID = consumeAuthorizationOperation(
            controllerID: ObjectIdentifier(controller)
        ) else { return }

        switch authorization.credential {
        case let appleIDCredential as ASAuthorizationAppleIDCredential:
            // Create an account in your system.
            // let userIdentifier = appleIDCredential.user
            let fullName = appleIDCredential.fullName
            let email = appleIDCredential.email
            let authorizationCode = appleIDCredential.authorizationCode
            var userAppleSignInData: AppleSignInData? = nil

            if let email = email {
                // Store email and fullName in AppleSignInData struct if available
                userAppleSignInData = AppleSignInData(
                    email: email,
                    firstName: fullName?.givenName,
                    lastName: fullName?.familyName,
                    fullName: getFullName(firstName: fullName?.givenName, lastName: fullName?.familyName)
                )
                let encoder = JSONEncoder()
                if let encoded = try? encoder.encode(userAppleSignInData) {
                    let defaults = UserDefaults.standard
                    defaults.set(encoded, forKey: appleSignInDataKey)
                }
            }

            if let authorizationCode = authorizationCode,
               let authCode = String(data: authorizationCode, encoding: .utf8) {

                let intent = self.intent
                let task = Task {
                    let hubRequestID = UUID()
                    guard await self.presentHubForNativeCompletion(
                        operationID: operationID,
                        hubRequestID: hubRequestID
                    ) else { return }
                    await self.completeSignIn(
                        authorizationCode: authCode,
                        fullName: fullName,
                        email: email,
                        intent: intent,
                        hubRequestID: hubRequestID,
                        operationID: operationID
                    )
                }
                setCompletionTask(task, for: operationID)
            } else {
                logger.error("Missing data from Apple sign-in response: \(String(describing: appleIDCredential))")
                Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                    loginStep: .error,
                    signInType: .apple
                ))
            }

        default:
            logger.error("Unknown credential type returned from Apple ID sign-in: \(String(describing: authorization.credential))")
            Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                loginStep: .error,
                signInType: .apple
            ))
            break
        }
    }

    func completeSignIn(
        authorizationCode: String,
        fullName: PersonNameComponents?,
        email: String?,
        intent: RowndSignInIntent?,
        hubRequestID: UUID
    ) async {
        let operationID = beginOperation()
        guard bindHubRequest(hubRequestID, to: operationID) else { return }
        await completeSignIn(
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: email,
            intent: intent,
            hubRequestID: hubRequestID,
            operationID: operationID
        )
    }

    func presentHubForNativeCompletion(operationID: UUID, hubRequestID: UUID) async -> Bool {
        guard bindHubRequest(hubRequestID, to: operationID) else { return false }
        await beforeHubPresentation()
        guard isCurrentOperation(operationID) else { return false }
        return await MainActor.run {
            guard self.isCurrentOperation(operationID),
                  self.isHubRequestBound(hubRequestID, to: operationID) else {
                return false
            }
            Rownd.requestSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                requestID: hubRequestID
            )
            return true
        }
    }

    private func completeSignIn(
        authorizationCode: String,
        fullName: PersonNameComponents?,
        email: String?,
        intent: RowndSignInIntent?,
        hubRequestID: UUID,
        operationID: UUID
    ) async {
        guard let clientType = await resolveAppleClientType() else {
            guard isCurrentOperation(operationID) else { return }
            logger.error("Apple sign-in requires a non-empty ios_client_type in app config")
            await MainActor.run {
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .apple
                    ),
                    requestID: hubRequestID
                )
            }
            return
        }

        let signInResponse: SuperTokensThirdPartySignInResponse
        do {
            signInResponse = try await signInWithApple(authorizationCode, clientType)
        } catch {
            guard isCurrentOperation(operationID) else { return }
            await MainActor.run {
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .apple
                    ),
                    requestID: hubRequestID
                )
            }
            return
        }

        guard isCurrentOperation(operationID) else { return }
        guard await syncAuthState() else {
            guard isCurrentOperation(operationID) else { return }
            await MainActor.run {
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .apple
                    ),
                    requestID: hubRequestID
                )
            }
            return
        }
        guard isCurrentOperation(operationID) else { return }

        if Rownd.isNativeHubRequestActive(hubRequestID) {
            await MainActor.run {
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: RowndSignInLoginStep.success,
                        intent: intent,
                        userType: signInResponse.userType,
                        appVariantUserType: signInResponse.userType
                    ),
                    requestID: hubRequestID
                )
            }

            // Prevent fast auth handshakes from feeling jarring to the user
            await waitBeforeCompletion()
            if isCurrentOperation(operationID), Rownd.isNativeHubRequestActive(hubRequestID) {
                await dismissHub(hubRequestID)
                clearHubRequest(hubRequestID, for: operationID)
            }
        }

        guard isCurrentOperation(operationID) else { return }
        await MainActor.run {
            guard self.isCurrentOperation(operationID) else { return }
            Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.apple))
            self.updateUserDataWithAppleData(fullName: fullName, email: email)
        }
        guard isCurrentOperation(operationID) else { return }
        await emitEvent(RowndEvent(
            event: .signInCompleted,
            data: [
                "method": AnyCodable(SignInType.apple.rawValue),
                "user_type": AnyCodable(signInResponse.userType.rawValue),
                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
            ]
        ))
    }

    private func beginOperation() -> UUID {
        operationLock.lock()
        completionTask?.cancel()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        operationLock.unlock()
        retireHubRequest(previousHubRequestID)
        return operationID
    }

    @discardableResult
    func registerAuthorizationOperation(controllerID: ObjectIdentifier) -> UUID {
        operationLock.lock()
        completionTask?.cancel()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        authorizationOperations[controllerID] = operationID
        operationLock.unlock()
        retireHubRequest(previousHubRequestID)
        return operationID
    }

    func consumeAuthorizationOperation(controllerID: ObjectIdentifier) -> UUID? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let operationID = authorizationOperations.removeValue(forKey: controllerID),
              currentOperationID == operationID else {
            return nil
        }
        return operationID
    }

    private func bindHubRequest(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard currentOperationID == operationID else { return false }
        currentHubRequestID = hubRequestID
        return true
    }

    private func isHubRequestBound(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return currentOperationID == operationID && currentHubRequestID == hubRequestID
    }

    private func clearHubRequest(_ hubRequestID: UUID, for operationID: UUID) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard currentOperationID == operationID,
              currentHubRequestID == hubRequestID else { return }
        currentHubRequestID = nil
    }

    private func retireHubRequest(_ hubRequestID: UUID?) {
        guard let hubRequestID else { return }
        Task { await dismissHub(hubRequestID) }
    }

    private func setCompletionTask(_ task: Task<Void, Never>, for operationID: UUID) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard currentOperationID == operationID else {
            task.cancel()
            return
        }
        completionTask = task
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        let isCancelled = withUnsafeCurrentTask { $0?.isCancelled == true }
        return currentOperationID == operationID && !isCancelled
    }

    private func resolveAppleClientType() async -> String? {
        let appConfigBeforeFetch = await MainActor.run {
            Context.currentContext.store.state.appConfig
        }
        if let clientType = Self.configuredAppleClientType(in: appConfigBeforeFetch) {
            return clientType
        }

        guard let fetchedAppConfig = await fetchAppConfig() else {
            return nil
        }

        return await MainActor.run {
            let store = Context.currentContext.store
            let currentAppConfig = store.state.appConfig
            guard Self.appConfigStatesEqualIgnoringLoading(
                currentAppConfig,
                appConfigBeforeFetch
            ) else {
                return Self.configuredAppleClientType(in: currentAppConfig)
            }

            guard let clientType = Self.configuredAppleClientType(in: fetchedAppConfig.app) else {
                return nil
            }
            store.dispatch(SetAppConfig(payload: fetchedAppConfig.app))
            return clientType
        }
    }

    private static func appConfigStatesEqualIgnoringLoading(
        _ lhs: AppConfigState,
        _ rhs: AppConfigState
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.isLoading = false
        rhs.isLoading = false
        return lhs == rhs
    }

    private static func configuredAppleClientType(in appConfig: AppConfigState) -> String? {
        guard let clientType = appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientType.isEmpty else {
            return nil
        }
        return clientType
    }

    @MainActor func updateUserDataWithAppleData(fullName: PersonNameComponents?, email: String?) {
        Context.currentContext.store.dispatch(Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }
            Task {
                do {
                    if let userStateResponse = try await UserData.fetchUserData(state) {
                        var userData = state.user.data
                        userData.merge(userStateResponse.data) { (current, _) in current }
                        var appleUserData: [String: AnyCodable] = [:]

                        let defaults = UserDefaults.standard
                        // use UserDefault values for Email and fullName if available
                        if let userAppleSignInData = defaults.object(forKey: appleSignInDataKey) as? Data {
                            let decoder = JSONDecoder()
                            if let loadedAppleSignInData = try? decoder.decode(AppleSignInData.self, from: userAppleSignInData) {
                                appleUserData = loadedAppleSignInData.toDictionary()
                            }
                            
                            // Remove the data since we no longer need it for subsequent signins.
                            defaults.removeObject(forKey: appleSignInDataKey)
                        } else {
                            if let email = email {
                                let name = [fullName?.givenName, fullName?.familyName]
                                    .compactMap { $0 }
                                    .joined(separator: " ")
                                appleUserData = AppleSignInData(
                                    email: email,
                                    firstName: fullName?.givenName,
                                    lastName: fullName?.familyName,
                                    fullName: name.isEmpty ? nil : name
                                ).toDictionary()
                            }
                        }

                        if !appleUserData.isEmpty {
                            userData.merge(appleUserData) { (_, updated) in updated }
                            await MainActor.run {
                                dispatch(UserData.save(appleUserData, optimisticData: userData))
                            }
                            logger.debug("UserData to save after signin: \(String(describing: appleUserData))")
                        }
                    } else {
                        // Handle the case where userStateResponse is nil
                        logger.error("Failed to fetch user state response")
                    }
                } catch {
                    // Handle any errors that occurred during fetch
                    logger.error("Error fetching user data: \(error)")
                }
            }
        })
    }

    // If authorization faced any issue then this method will get triggered
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard consumeAuthorizationOperation(
            controllerID: ObjectIdentifier(controller)
        ) != nil else { return }

        // If there is any error will get it here
        logger.error("An error occurred while signing in with Apple. Error: \(String(describing: error))")
        
        func defaultSignInFlow() {
            logger.error("Falling back to default sign flow")
            Rownd.requestSignIn(RowndSignInOptions(intent: intent))
        }

        guard let authorizationError = error as? ASAuthorizationError else {
            defaultSignInFlow()
            return
        }

        switch authorizationError.code {
        case .canceled:
            return
        default:
            defaultSignInFlow()
        }
    }
}
