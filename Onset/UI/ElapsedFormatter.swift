// MARK: - ElapsedFormatter

/// Formats whole seconds as `mm:ss` (up to 59:59) or `h:mm:ss` when an hour or more has elapsed.
///
/// Avoids `String(format:)`, whose variadic initializer trips `SWIFT_STRICT_MEMORY_SAFETY` (the
/// project enables strict memory safety). Pads each component to two digits manually.
nonisolated enum ElapsedFormatter {
    private static let secondsPerMinute = 60
    private static let minutesPerHour = 60
    private static let secondsPerHour = secondsPerMinute * minutesPerHour
    private static let twoDigitThreshold = 10

    /// Returns a human-readable elapsed time string.
    ///
    /// - For `seconds` < 3600: `"mm:ss"` (e.g. `"04:17"`)
    /// - For `seconds` ≥ 3600: `"h:mm:ss"` (e.g. `"1:04:17"`)
    static func string(from seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        let hours = totalSeconds / self.secondsPerHour
        let remainder = totalSeconds % self.secondsPerHour
        let minutes = remainder / self.secondsPerMinute
        let secs = remainder % self.secondsPerMinute

        if hours > 0 {
            return "\(hours):\(self.padded(minutes)):\(self.padded(secs))"
        } else {
            return "\(self.padded(minutes)):\(self.padded(secs))"
        }
    }

    private static func padded(_ value: Int) -> String {
        value < self.twoDigitThreshold ? "0\(value)" : "\(value)"
    }
}
