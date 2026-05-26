//
//  SignInLinks.swift
//  RowndSDK
//
//  Created by Matt Hamann on 8/16/22.
//

import Foundation
import Get
import UIKit

public protocol RowndDeepLinkHandlerDelegate {
    @discardableResult
    func handle(linkUrl url: URL) -> Bool
}

class SmartLinks {
    private static var lastHandledDeepLink: URL?

    static func handleSmartLinkLaunchBehavior(launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
        if !Bundle.main.bundlePath.hasSuffix(".appex") {
            var launchUrl: URL?
            if let _launchUrl = launchOptions?[.url] as? URL {
                launchUrl = _launchUrl
                handleSmartLink(url: launchUrl)
            } else if Rownd.config.enableSmartLinkPasteBehavior && UIPasteboard.general.hasStrings {
                if let clipboardString = UIPasteboard.general.string,
                   clipboardString.starts(with: "\(Rownd.config.deepLinkScheme)://") {
                    handleSmartLink(url: URL(string: clipboardString))
                    UIPasteboard.general.string = ""
                    return
                }

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
        guard let url = url else {
            return false
        }

        if let hubUrl = hubUrl(for: url) {
            if lastHandledDeepLink == url {
                return true
            }

            lastHandledDeepLink = url
            Rownd.openHubDeepLink(hubUrl)
            return true
        }

        let matcher = NSPredicate(format: "SELF MATCHES %@", Rownd.config.signInLinkPattern)

        if let host = url.host, matcher.evaluate(with: host) {
            logger.trace("handling url: \(String(describing: url.absoluteString))")

            if url.path.starts(with: "/verified") {
                return false
            }

            var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true)
            urlComponents?.scheme = "https"

            guard let url = urlComponents?.url else {
                return false
            }

            logger.warning("Legacy Rownd smart links are not supported by the SuperTokens-backed iOS SDK: \(url.absoluteString)")
            return false
        }

        return false
    }

    private static func hubUrl(for url: URL) -> URL? {
        guard url.scheme == Rownd.config.deepLinkScheme,
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hubPath = path.isEmpty ? "/\(host)" : "/\(host)/\(path)"
        guard hubPath == "/account/login" || hubPath == "/account/verify-email" else {
            return nil
        }

        guard var components = URLComponents(string: Rownd.config.baseUrl) else {
            return nil
        }

        components.path = hubPath
        components.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        components.fragment = url.fragment
        return components.url
    }
}
