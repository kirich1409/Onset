import CoreMedia
import Domain

// MARK: - HostClockService

/// Concrete implementation of `ClockProviding` backed by `CMClockGetHostTimeClock()`.
///
/// `CMClockGetHostTimeClock()` returns the canonical system host-time clock — the same
/// reference used by all Apple capture frameworks (ScreenCaptureKit, AVFoundation) to
/// timestamp samples. All `CaptureSource` implementations present their device PTS on
/// this common base, so no conversion is needed when `src === referenceClock` (identity).
///
/// ## Sendability
///
/// `HostClockService` is a value type (`struct`) storing a single `let CMClock`.
/// `CMClock` is `Sendable` in the macOS 26 SDK, so the struct inherits synthesised
/// `Sendable` conformance without `@unchecked`. No additional annotation is required.
///
/// ## Usage
///
/// ```swift
/// let clock = HostClockService()
/// // Inject into each CaptureSource and the session coordinator.
/// ```
///
/// Composition-root wiring is deferred to issue #36.
public struct HostClockService: ClockProviding {

    // MARK: - ClockProviding

    /// The system host-time clock, shared by all capture sources.
    ///
    /// Stored once at initialisation. `CMClockGetHostTimeClock()` always returns the
    /// same singleton so repeated calls are equivalent, but storing it avoids the
    /// (negligible) CF lookup on every hot-path access.
    public let referenceClock: CMClock

    // MARK: - Initialisation

    public init() {
        referenceClock = CMClockGetHostTimeClock()
    }

    // MARK: - ClockProviding methods

    /// Returns the current host time as a `CMTime`.
    ///
    /// Wraps `CMClockGetTime(referenceClock)`. Monotonically non-decreasing; two
    /// successive calls may return equal values at very high clock resolution.
    public func now() -> CMTime {
        CMClockGetTime(referenceClock)
    }

    /// Converts `time` (expressed in `src`'s time base) to the host-time base.
    ///
    /// Wraps `CMSyncConvertTime`. When `src` is `referenceClock` the result is the
    /// identity — `CMSyncConvertTime` detects this and returns `time` unchanged.
    ///
    /// - Parameters:
    ///   - time: The timestamp to convert. The caller is responsible for passing a
    ///     numeric `CMTime`; an invalid input yields an invalid result (`CMTime.invalid`).
    ///     `AudioCaptureSource` guards `.isNumeric` before calling this method.
    ///   - src: The clock that generated `time`. Must be synchronisable to
    ///     `referenceClock`; unsynchronisable clocks also yield `CMTime.invalid`.
    /// - Returns: The equivalent timestamp in the host-time base.
    public func convert(_ time: CMTime, from src: CMClock) -> CMTime {
        CMSyncConvertTime(time, from: src, to: referenceClock)
    }
}
