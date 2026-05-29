import Domain

// Placeholder so the Application target compiles before the coordinator/stores exist.
// The Swift implementation stage replaces this with RecordingSessionCoordinator,
// SettingsStore, RuntimeHealthMonitor, etc.
public enum ApplicationPlaceholder {
    public static let layer = "Application"
    public static let dependsOn = DomainPlaceholder.layer
}
