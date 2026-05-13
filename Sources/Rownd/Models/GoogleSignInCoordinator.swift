//
//  GoogleSignInCoordinator.swift
//  Rownd
//
//  Created by Matt Hamann on 4/4/23.
//

import Foundation
import GoogleSignIn
import UIKit
import AnyCodable
import JWTDecode

class GoogleSignInCoordinator: NSObject {
    var parent: Rownd
    var intent: RowndSignInIntent?
    var signInClient = SuperTokensThirdPartySignInClient()

    init(_ parent: Rownd) {
        self.parent = parent
        super.init()
    }

    func signIn(_ intent: RowndSignInIntent?) async {
        await signIn(intent, hint: nil)
    }

    func defaultSignInFlow() {
        logger.error("Falling back to default sign flow")
        Rownd.requestSignIn(RowndSignInOptions(intent: intent))
    }

    /// Sign in funciton for customer-provided web views
    func signIn(webViewId: String, intent: RowndSignInIntent?, hint: String?) -> Void {
        let googleConfig = Context.currentContext.store.state.appConfig.config?.hub?.auth?.signInMethods?.google

        guard let iosClientId = googleConfig?.iosClientId, let serverClientId = googleConfig?.serverClientId else {
            logger.error("Google sign-in config missing required properties")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: iosClientId,
            serverClientID: serverClientId
        )

        Task { @MainActor in
            guard let rootViewController = parent.getRootViewController() else {
                logger.error("Failed to retrieve root view controller")
                return
            }
            
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )
                
                guard let idToken = result.user.idToken else {
                    Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: "window.rownd.requestSignIn({ 'login_step': 'error', 'sign_in_type': 'google' });")
                    logger.error("Google sign-in failed. Either no ID token was present, or an error was thrown.")
                    return
                }
                
                logger.debug("Sign-in handshake with Google completed successfully.")
                do {
                    Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: "window.rownd.requestSignIn({ 'login_step': 'completing' });")
                    
                    _ = try await signInClient.signInWithGoogle(idToken: idToken.tokenString)
                    await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

                    guard let accessToken = await SuperTokensSessionBridge.getAccessToken() else {
                        logger.error("Token response is empty")
                        return
                    }
                    
                    // Reload the web view page with rph_init appended to the URL fragment in order
                    // to complete the sign-in
                    do {
                        let jwt = try decode(jwt: accessToken)
                        let appId = jwt.audience?.first(where: {
                            return $0.starts(with: "app:")
                        })?.replacingOccurrences(of: "app:", with: "")
                        let appUserId = jwt.claim(name: "https://auth.rownd.io/app_user_id")
                        
                        let rphInit = RphInit(
                            accessToken: accessToken,
                            refreshToken: nil,
                            appId: appId ?? Context.currentContext.store.state.appConfig.id,
                            appUserId: appUserId.string
                        )
                        
                        let rphInitString = try rphInit.valueForURLFragment()
                        Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: """
                            let url = new URL(window.location.href);
                            let fragmentParts = url.hash?.split(',') || [];
                            fragmentParts.push(`rph_init=\(rphInitString)`);
                            url.hash = fragmentParts.join(',');
                            window.location.replace(url.toString());
                            window.location.reload(); // It would be best if we didn't have to reload, but the Hub has problems handling updated rph_ hash values without doing a full reload.
                        """)
                        return
                    } catch {
                        logger.error("Failed to build rph_init hash string: \(String(describing: error))")
                        return
                    }
                } catch ApiError.generic(let errorInfo) {
                    logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: errorInfo))")
                }
            } catch {
                logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: error))")
            }
        }
    }

    func signIn(_ intent: RowndSignInIntent?, hint: String?) async {
        let googleConfig = Context.currentContext.store.state.appConfig.config?.hub?.auth?.signInMethods?.google
        guard googleConfig?.enabled == true, let googleConfig = googleConfig else {
            logger.error("Sign in with Google is not enabled. Turn it on in the Rownd platform")
            defaultSignInFlow()
            return
        }

        if googleConfig.serverClientId == nil ||
            googleConfig.serverClientId == "" ||
            googleConfig.iosClientId == nil ||
            googleConfig.iosClientId == "" {
            logger.error("Cannot sign in with Google. Missing client configuration")
            defaultSignInFlow()
            return
        }

        let reversedClientId = googleConfig.iosClientId!.split(separator: ".").reversed().joined(separator: ".")
        if let url = NSURL(string: reversedClientId + "://") {
            if await UIApplication.shared.canOpenURL(url as URL) == false {
                logger.error("Cannot sign in with Google. \(String(describing: reversedClientId)) is not defined in URL schemes")
                defaultSignInFlow()
                return
            }
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: (googleConfig.iosClientId)!,   // (IOS)
            serverClientID: googleConfig.serverClientId  // (Web)
        )

        Task { @MainActor in
            guard let rootViewController = parent.getRootViewController() else {
                logger.error("Failed to retrieve root view controller")
                defaultSignInFlow()
                return
            }

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )

                guard let idToken = result.user.idToken else {
                    Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .google
                    ))
                    logger.error("Google sign-in failed. Either no ID token was present, or an error was thrown.")
                    return
                }

                Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                    loginStep: .completing
                ))

                logger.debug("Sign-in handshake with Google completed successfully.")
                do {
                    let signInResponse = try await signInClient.signInWithGoogle(idToken: idToken.tokenString)
                    await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

                    Task { @MainActor in
                        Context.currentContext.store.dispatch(UserData.fetch())
                        Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.google))

                        Rownd.requestSignIn(
                            jsFnOptions: RowndSignInJsOptions(
                                loginStep: .success,
                                intent: intent,
                                userType: signInResponse.userType,
                                appVariantUserType: signInResponse.userType
                            )
                        )
                        
                        RowndEventEmitter.emit(RowndEvent(
                            event: .signInCompleted,
                            data: [
                                "method": AnyCodable(SignInType.google.rawValue),
                                "user_type": AnyCodable(signInResponse.userType.rawValue),
                                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
                            ]
                        ))
                    }
                    return
                } catch ApiError.generic(let errorInfo) {
                    if errorInfo.code == "E_SIGN_IN_USER_NOT_FOUND" {
                        Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                            token: idToken.tokenString,
                            loginStep: .noAccount,
                            intent: .signIn
                        ))
                    } else {
                        DispatchQueue.main.async {
                            Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                                loginStep: .error,
                                signInType: .google
                            ))
                        }
                    }
                    logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: errorInfo))")
                    return
                } catch {
                    Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .google
                    ))
                    logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: error))")
                    return
                }
            }
        }
    }
}
