//
//  File.swift
//
//
//  Created by Matt Hamann on 4/26/24.
//

import Foundation
import UIKit

class AppStateListener {

    private let nc = NotificationCenter.default

    init() {
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func appMovedToBackground() {
        UserData.fetchCoordinator.cancelCurrent()
        Task {
            await UserData.profileHydrationRetryCoordinator.cancel()
        }
    }

    @objc func appBecameActive() {
        Task {
            await Rownd.fetchInitialForegroundProfileIfNeeded()
        }
    }
}
