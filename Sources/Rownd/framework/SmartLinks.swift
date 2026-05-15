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

            logger.warning("Legacy Rownd smart links are not supported by the SuperTokens-backed iOS SDK: \(url.absoluteString)")
            return false
        }

        return false
    }
}
