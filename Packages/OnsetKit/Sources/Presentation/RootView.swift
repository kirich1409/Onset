import SwiftUI

// Minimal composition root view. Displays the app name from the String Catalog
// via Bundle.module — no hardcoded UI strings (NFR-I18N).
public struct RootView: View {
    public init() {}

    public var body: some View {
        Text("root.greeting", bundle: .module)
    }
}
