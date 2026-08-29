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

class AppleSignUpCoordinator: NSObject {
    @MainActor private var currentOperationID: UUID?
    @MainActor private var completionTask: Task<Void, Never>?
    @MainActor private var currentHubRequestID: UUID?
    @MainActor private var authorizationOperations: [ObjectIdentifier: UUID] = [:]
    var parent: Rownd?
    var intent: RowndSignInIntent?
    var cancellables = Set<AnyCancellable>()
    var signInWithApple: (String, String) async throws -> SuperTokensThirdPartySignInResponse
    var fetchAppConfig: () async -> AppConfigResponse? = {
        await AppConfig.fetch()
    }
    var syncAuthState: (@MainActor () -> Bool) async -> Bool = { commitIf in
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
            afterTokenRead: {},
            commitIf: commitIf
        )
    }
    var waitBeforeCompletion: () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(2 * Double(NSEC_PER_SEC)))
    }
    var beforeHubPresentation: () async -> Void = {}
    var beforeFinalization: () async -> Void = {}
    var dismissHub: (UUID) async -> Void = { requestID in
        await Rownd.dismissHub(requestID: requestID)
    }
    var emitEvent: @MainActor (RowndEvent) -> Void = { event in
        RowndEventEmitter.emit(event)
    }
    @MainActor private lazy var authorizationDelegate = AppleAuthorizationDelegate(coordinator: self)

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
        DispatchQueue.main.async { [weak self] in
            self?.signInOnMainActor(intent)
        }
    }

    @MainActor private func signInOnMainActor(_ intent: RowndSignInIntent?) {
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
        authorizationController.presentationContextProvider = authorizationDelegate
        authorizationController.delegate = authorizationDelegate
        registerAuthorizationOperation(controllerID: ObjectIdentifier(authorizationController))
        authorizationController.performRequests()
    }

    private func getFullName(firstName: String?, lastName: String?) -> String {
        return String("\(firstName ?? "") \(lastName ?? "")")
    }

    @MainActor fileprivate func completeAuthorization(
        controllerID: ObjectIdentifier,
        authorization: ASAuthorization
    ) {
        guard let operationID = consumeAuthorizationOperation(controllerID: controllerID) else { return }

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
        let operationID = await beginOperation()
        guard await bindHubRequest(hubRequestID, to: operationID) else { return }
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
        guard await bindHubRequest(hubRequestID, to: operationID) else { return false }
        await beforeHubPresentation()
        guard await isCurrentOperation(operationID) else { return false }
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
            guard await isCurrentOperation(operationID) else { return }
            logger.error("Apple sign-in requires a non-empty ios_client_type in app config")
            await MainActor.run {
                guard self.isCurrentOperation(operationID) else { return }
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
            guard await isCurrentOperation(operationID) else { return }
            await MainActor.run {
                guard self.isCurrentOperation(operationID) else { return }
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

        let didPresentSuccess = await MainActor.run {
            guard self.isCurrentOperation(operationID),
                  Rownd.isNativeHubRequestActive(hubRequestID) else {
                return false
            }
            Rownd.updateSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(
                    loginStep: RowndSignInLoginStep.success,
                    intent: intent,
                    userType: signInResponse.userType,
                    appVariantUserType: signInResponse.userType
                ),
                requestID: hubRequestID
            )
            return true
        }
        if didPresentSuccess {
            // Prevent fast auth handshakes from feeling jarring to the user
            await waitBeforeCompletion()
            let shouldDismissHub = await MainActor.run {
                self.isCurrentOperation(operationID)
                    && Rownd.isNativeHubRequestActive(hubRequestID)
            }
            if shouldDismissHub {
                await dismissHub(hubRequestID)
                await clearHubRequest(hubRequestID, for: operationID)
            }
        }

        guard await canCommitAuthState(
            operationID: operationID,
            hubRequestID: hubRequestID
        ) else { return }
        let commitAuthState: @MainActor () -> Bool = {
            self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID
            )
        }
        guard await syncAuthState(commitAuthState) else {
            guard await canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID
            ) else { return }
            await presentSyncFailure(
                replacing: hubRequestID,
                operationID: operationID
            )
            return
        }

        await beforeFinalization()
        let completionEvent = RowndEvent(
            event: .signInCompleted,
            data: [
                "method": AnyCodable(SignInType.apple.rawValue),
                "user_type": AnyCodable(signInResponse.userType.rawValue),
                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
            ]
        )
        await MainActor.run {
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID
            ) else { return }
            Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.apple))
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID
            ) else { return }
            self.updateUserDataWithAppleData(fullName: fullName, email: email)
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID
            ) else { return }
            self.emitEvent(completionEvent)
        }
    }

    @MainActor private func canCommitAuthState(operationID: UUID, hubRequestID: UUID) -> Bool {
        isCurrentOperation(operationID)
            && Rownd.canCommitAuthState(forNativeHubRequest: hubRequestID)
    }

    private func presentSyncFailure(replacing completedRequestID: UUID, operationID: UUID) async {
        let fallbackRequestID = UUID()
        guard await bindHubRequest(fallbackRequestID, to: operationID) else { return }

        let didPresent = await MainActor.run {
            guard self.isCurrentOperation(operationID),
                  self.isHubRequestBound(fallbackRequestID, to: operationID) else {
                return false
            }
            return Rownd.requestSignInForNativeCompletionFallback(
                jsFnOptions: RowndSignInJsOptions(
                    loginStep: .error,
                    signInType: .apple
                ),
                replacing: completedRequestID,
                requestID: fallbackRequestID
            )
        }
        if !didPresent {
            await clearHubRequest(fallbackRequestID, for: operationID)
        }
    }

    @MainActor private func beginOperation() -> UUID {
        completionTask?.cancel()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        retireHubRequest(previousHubRequestID)
        return operationID
    }

    @discardableResult
    @MainActor func registerAuthorizationOperation(controllerID: ObjectIdentifier) -> UUID {
        completionTask?.cancel()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        authorizationOperations[controllerID] = operationID
        retireHubRequest(previousHubRequestID)
        return operationID
    }

    @MainActor func consumeAuthorizationOperation(controllerID: ObjectIdentifier) -> UUID? {
        guard let operationID = authorizationOperations.removeValue(forKey: controllerID),
              currentOperationID == operationID else {
            return nil
        }
        return operationID
    }

    @MainActor private func bindHubRequest(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        guard currentOperationID == operationID else { return false }
        currentHubRequestID = hubRequestID
        return true
    }

    @MainActor private func isHubRequestBound(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        return currentOperationID == operationID && currentHubRequestID == hubRequestID
    }

    @MainActor private func clearHubRequest(_ hubRequestID: UUID, for operationID: UUID) {
        guard currentOperationID == operationID,
              currentHubRequestID == hubRequestID else { return }
        currentHubRequestID = nil
    }

    private func retireHubRequest(_ hubRequestID: UUID?) {
        guard let hubRequestID else { return }
        Task { await dismissHub(hubRequestID) }
    }

    @MainActor private func setCompletionTask(_ task: Task<Void, Never>, for operationID: UUID) {
        guard currentOperationID == operationID else {
            task.cancel()
            return
        }
        completionTask = task
    }

    @MainActor private func isCurrentOperation(_ operationID: UUID) -> Bool {
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

    @MainActor fileprivate func completeAuthorization(
        controllerID: ObjectIdentifier,
        error: Error
    ) {
        guard consumeAuthorizationOperation(controllerID: controllerID) != nil else { return }

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

private final class AppleAuthorizationDelegate: NSObject,
                                                ASAuthorizationControllerDelegate,
                                                ASAuthorizationControllerPresentationContextProviding {
    private weak var coordinator: AppleSignUpCoordinator?

    init(coordinator: AppleSignUpCoordinator) {
        self.coordinator = coordinator
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let viewController = UIApplication.shared.windows.last?.rootViewController
        return (viewController?.view.window!)!
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let controllerID = ObjectIdentifier(controller)
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.completeAuthorization(
                controllerID: controllerID,
                authorization: authorization
            )
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let controllerID = ObjectIdentifier(controller)
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.completeAuthorization(controllerID: controllerID, error: error)
        }
    }
}
