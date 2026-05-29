import Application
import Domain

// Placeholder composition root for the app. The Swift implementation stage replaces
// this with the real RootView (SwiftUI) + AppKit menu-bar wiring and the full
// composition root. The app target links the `Presentation` product and references
// `RootComposition.appLayer` from `onsetApp.swift` so that `xcodebuild build` proves
// the product is actually linked into the app bundle (not just resolved by SwiftPM).
public enum RootComposition {
    public static let appLayer = "Presentation"
    public static let applicationLayer = ApplicationPlaceholder.layer
    public static let domainLayer = "Domain"
}
