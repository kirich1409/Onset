import os

// Sanctioned logging facade for Onset. All layers import Domain, so this facade
// is available everywhere. The no-print gate enforces use of this facade over bare output.
//
// Usage:
//   Log.general.debug("message")
//   Log.general.error("error occurred")
public enum Log {
    public static let general = Logger(
        subsystem: "dev.androidbroadcast.onset",
        category: "general"
    )

    public static func debug(_ message: String, category: String = "general") {
        Logger(subsystem: "dev.androidbroadcast.onset", category: category)
            .debug("\(message, privacy: .public)")
    }

    public static func error(_ message: String, category: String = "general") {
        Logger(subsystem: "dev.androidbroadcast.onset", category: category)
            .error("\(message, privacy: .public)")
    }
}
