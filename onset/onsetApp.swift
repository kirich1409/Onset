//
//  onsetApp.swift
//  onset
//
//  Created by Kirill Rozov on 29.05.2026.
//

import Infrastructure
import Presentation
import SwiftUI

@main
struct OnsetApp: App {

    // Concrete `PermissionsManager` (Infrastructure) is constructed here in the app target —
    // the only layer that links both Presentation and Infrastructure. RootComposition receives
    // it as `any PermissionsProviding` so Presentation never imports Infrastructure directly.
    @MainActor private let root = RootComposition(permissions: PermissionsManager())

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
