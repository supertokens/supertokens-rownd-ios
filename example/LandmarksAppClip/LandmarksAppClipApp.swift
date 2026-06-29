//
//  LandmarksAppClipApp.swift
//  LandmarksAppClip
//
//  Created by Matt Hamann on 3/26/25.
//

import SwiftUI
import Rownd

@main
struct LandmarksAppClipApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .rowndDeepLinkHandler()
        }
    }
}
