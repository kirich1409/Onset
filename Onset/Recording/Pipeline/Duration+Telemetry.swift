import Foundation

extension Duration {
    /// Total elapsed time as a `Double` in seconds.
    ///
    /// Used by the periodic ~1 s telemetry flush tasks in
    /// `VideoEncoder`, `FileWriter`, `ScreenSource`, and `CameraSource`
    /// to convert a `ContinuousClock` interval to the scalar the
    /// `StageRateAggregator` flush API expects.
    nonisolated var totalSeconds: Double {
        let parts = self.components
        // 1e-18: structural constant converting attoseconds to seconds (1 s = 10^18 as).
        // swiftlint:disable:next no_magic_numbers
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
