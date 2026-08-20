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
    var parent: Rownd?
    var intent: RowndSignInIntent?
    var cancellables = Set<AnyCancellable>()
    var signInWithApple: (String, String?) async throws -> SuperTokensThirdPartySignInResponse
    var syncAuthState: () async -> Void = {
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
    }
    var waitBeforeCompletion: () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(2 * Double(NSEC_PER_SEC)))
    }
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
                Task {
                    let hubRequestID = UUID()
                    await MainActor.run {
                        Rownd.requestSignInForNativeCompletion(
                            jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                            requestID: hubRequestID
                        )
                    }
                    await self.completeSignIn(
                        authorizationCode: authCode,
                        fullName: fullName,
                        email: email,
                        intent: intent,
                        hubRequestID: hubRequestID
                    )
                }
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
        let signInResponse: SuperTokensThirdPartySignInResponse
        do {
            let clientType = Context.currentContext.store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            signInResponse = try await signInWithApple(authorizationCode, clientType)
            await syncAuthState()
        } catch {
            await MainActor.run {
                Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                    loginStep: .error,
                    signInType: .apple
                ))
            }
            return
        }

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
        await dismissHub(hubRequestID)

        await MainActor.run {
            Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.apple))
            self.updateUserDataWithAppleData(fullName: fullName, email: email)
        }
        await emitEvent(RowndEvent(
            event: .signInCompleted,
            data: [
                "method": AnyCodable(SignInType.apple.rawValue),
                "user_type": AnyCodable(signInResponse.userType.rawValue),
                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
            ]
        ))
    }

    func updateUserDataWithAppleData(fullName: PersonNameComponents?, email: String?) {
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
                            dispatch(UserData.save(appleUserData, optimisticData: userData))
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
