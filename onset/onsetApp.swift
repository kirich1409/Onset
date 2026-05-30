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
    // it as `any PermissionsProviding` / `any NotificationPermissionProviding` so Presentation
    // never imports Infrastructure directly. The same instance satisfies both protocols.
    @MainActor private let root: RootComposition = {
        let manager = PermissionsManager()
        return RootComposition(permissions: manager, notificationPermissions: manager)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
