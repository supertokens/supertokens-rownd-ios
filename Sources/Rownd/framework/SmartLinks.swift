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
            logger.debug("Smart link ignored: URL is nil")
            return false
        }

        logger.debug("Handling smart link: \(url.absoluteString)")

        if let hubUrl = hubUrl(for: url) {
            if lastHandledDeepLink == url {
                logger.debug("Smart link already handled: \(url.absoluteString)")
                return true
            }

            lastHandledDeepLink = url
            logger.debug("Smart link maps to Hub URL: \(hubUrl.absoluteString)")
            Rownd.openHubDeepLink(hubUrl)
            return true
        }

        if let host = url.host, matchesSignInLinkPattern(host) {
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

        logger.debug("Smart link ignored: no matching Hub URL or sign-in link pattern")
        return false
    }

    private static func hubUrl(for url: URL) -> URL? {
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            logger.debug("Smart link URL has no host: \(url.absoluteString)")
            return nil
        }

        guard var components = URLComponents(string: Rownd.config.baseUrl) else {
            logger.debug("Invalid Rownd Hub base URL: \(Rownd.config.baseUrl)")
            return nil
        }

        let hubPath: String
        if url.scheme == Rownd.config.deepLinkScheme {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hubPath = path.isEmpty ? "/\(host)" : "/\(host)/\(path)"
        } else if url.scheme == "https", host == components.host || matchesSignInLinkPattern(host) {
            hubPath = url.path
        } else {
            logger.debug("Smart link host/scheme did not match: scheme=\(url.scheme ?? "nil") host=\(host) baseHost=\(components.host ?? "nil") pattern=\(Rownd.config.signInLinkPattern)")
            return nil
        }

        guard hubPath == "/account/login" || hubPath == "/account/verify-email" else {
            logger.debug("Smart link path is unsupported: \(hubPath)")
            return nil
        }

        components.path = hubPath
        components.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        components.fragment = url.fragment
        return components.url
    }

    private static func matchesSignInLinkPattern(_ host: String) -> Bool {
        let matcher = NSPredicate(format: "SELF MATCHES %@", Rownd.config.signInLinkPattern)
        return matcher.evaluate(with: host)
    }
}
