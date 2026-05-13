//
//  SignInLinks.swift
//  RowndSDK
//
//  Created by Matt Hamann on 8/16/22.
//

import Foundation
import Get
import UIKit

struct SignInLinkResp: Hashable, Codable {
    public var accessToken: String?
    public var refreshToken: String?
    public var appId: String?
    public var appUserId: String?
    public var redirectUrl: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case appId = "app_id"
        case appUserId = "app_user_id"
        case redirectUrl = "redirect_url"
    }
}

public protocol RowndDeepLinkHandlerDelegate {
    @discardableResult
    func handle(linkUrl url: URL) -> Bool
}

class SmartLinks {
    static func handleSmartLinkLaunchBehavior(launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
        if !Bundle.main.bundlePath.hasSuffix(".appex") {
            var launchUrl: URL?
            if let _launchUrl = launchOptions?[.url] as? URL {
                launchUrl = _launchUrl
                handleSmartLink(url: launchUrl)
            } else if Rownd.config.enableSmartLinkPasteBehavior && UIPasteboard.general.hasStrings {
                UIPasteboard.general.detectPatterns(for: [UIPasteboard.DetectionPattern.probableWebURL]) { result in
                    switch result {
                    case .success(let detectedPatterns):
                        if detectedPatterns.contains(UIPasteboard.DetectionPattern.probableWebURL) {
                            if var _launchUrl = UIPasteboard.general.string {
                                if !_launchUrl.starts(with: "http") {
                                    _launchUrl = "https://\(_launchUrl)"
                                }
                                launchUrl = URL(string: _launchUrl)
                                handleSmartLink(url: launchUrl)
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    @discardableResult
    public static func handleSmartLink(url: URL?) -> Bool {

        let matcher = NSPredicate(format: "SELF MATCHES %@", Rownd.config.signInLinkPattern)

        if let host = url?.host, matcher.evaluate(with: host), let url = url {
            logger.trace("handling url: \(String(describing: url.absoluteString))")

            if url.path.starts(with: "/verified") {
                return false
            }

            var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true)
            urlComponents?.scheme = "https"

            guard let url = urlComponents?.url else {
                return false
            }

            Task {
                do {
                    try await SmartLinks.signInWithLink(url)
                } catch {
                    logger.error("Sign-in attempt failed during launch: \(String(describing: error))")
                }
            }

            return true
        }

        return false
    }

    static func signInWithLink(_ url: URL) async throws {
        do {
            var signInUrl = url
            if let fragment = signInUrl.fragment {
                signInUrl = URL(string: signInUrl.absoluteString.replacingOccurrences(of: "#\(fragment)", with: "")) ?? signInUrl
            }

            Task { @MainActor in
                if Rownd.isDisplayingHub() {
                    Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                        loginStep: .completing
                    ))
                }
            }
            let authResp: SignInLinkResp = try await Rownd.apiClient.send(Request(
                url: signInUrl,
                headers: [
                    "x-rownd-magic-allow-exp" : "true"
                ]
            )).value

            Task { @MainActor in
                if let accessToken = authResp.accessToken, let refreshToken = authResp.refreshToken {
                    Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(
                        accessToken: accessToken,
                        refreshToken: refreshToken
                    )))

                    Context.currentContext.store.dispatch(UserData.fetch())

                    if Rownd.isDisplayingHub() {
                        Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                            loginStep: .success
                        ))
                    }
                }

                guard let strRedirectUrl = authResp.redirectUrl, let redirectUrl = URL(string: strRedirectUrl) else {
                    return
                }

                Rownd.config.deepLinkHandler?.handle(linkUrl: redirectUrl)
            }
        } catch {
            Task { @MainActor in
                if Rownd.isDisplayingHub() {
                    Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error
                    ))
                }
            }
            logger.error("Auto sign-in failed: \(String(describing: error))")
            throw SignInError("Auto sign-in failed: \(error.localizedDescription)")
        }
    }
}

struct SignInError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}
