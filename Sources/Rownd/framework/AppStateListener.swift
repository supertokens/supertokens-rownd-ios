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
        // Future use
    }

    @objc func appBecameActive() {
        Task { @MainActor in
            let store = Context.currentContext.store
            guard store.state.auth.isAuthenticated else { return }
            store.dispatch(UserData.fetch())
        }
    }
}
