import AVFoundation
import CoreMedia
import os

// MARK: - Collector state

/// Snapshot of frame-delivery statistics collected by `Diag4KFrameCollector`.
struct Diag4KFrameSnapshot {
    /// Number of `CMSampleBuffer` callbacks received during the collection window.
    let frameCount: Int
    /// Width of the most recently delivered `CVPixelBuffer`, in pixels.
    let lastWidth: Int32
    /// Height of the most recently delivered `CVPixelBuffer`, in pixels.
    let lastHeight: Int32
    /// Four-character code of the most recently delivered pixel-buffer format (e.g. "420v").
    let lastFourCC: String
    /// Presentation timestamp of the first delivered sample, in seconds since host epoch.
    let firstTimestamp: Double
    /// Presentation timestamp of the last delivered sample, in seconds since host epoch.
    let lastTimestamp: Double
    /// PTS values (`.seconds`) of all delivered sample buffers, in arrival order.
    ///
    /// Capped at `Diag4KFrameCollector.ptsCap` entries to bound memory. Only samples with
    /// a numeric (finite) `CMTime` are included; indefinite/invalid timestamps are skipped.
    let ptsValues: [Double]
}

// MARK: - Delta statistics

/// Bucket bounds (in milliseconds) for the consecutive-PTS-delta histogram.
enum DeltaBucket {
    /// Upper bound for the "fast" bucket — deltas below this are sub-14ms.
    static let below: Double = 14
    /// Upper bound for the "≈16.7ms / 60fps" bucket.
    static let to20: Double = 20
    /// Upper bound for the "≈33ms / 30fps" bucket.
    static let to40: Double = 40
    /// Upper bound for the "≈50ms / 20fps" bucket.
    static let to60: Double = 60
    // Deltas ≥ 60ms fall in the ">60" overflow bucket.
}

/// Computed inter-frame PTS delta statistics derived from a `Diag4KFrameSnapshot`.
struct Diag4KDeltaStats {
    /// Number of consecutive PTS deltas analysed (`ptsCount - 1`).
    let deltaCount: Int
    /// Mean of consecutive deltas, in milliseconds.
    let meanMs: Double
    /// Minimum observed consecutive delta, in milliseconds.
    let minMs: Double
    /// Maximum observed consecutive delta, in milliseconds.
    let maxMs: Double
    /// Standard deviation of consecutive deltas, in milliseconds.
    let stdMs: Double
    /// Frames per second derived from the PTS span (`(count-1) / (lastPTS - firstPTS)`).
    /// Zero when fewer than two valid PTS values are available.
    let ptsFps: Double

    /// Histogram counts by inter-frame delta magnitude (in ms):
    /// deltas below 14 ms.
    let histBelow14: Int
    /// Deltas in [14, 20) ms — the ≈60fps cadence bucket.
    let hist14to20: Int
    /// Deltas in [20, 40) ms — the ≈30fps cadence bucket.
    let hist20to40: Int
    /// Deltas in [40, 60) ms — the ≈20fps cadence bucket.
    let hist40to60: Int
    /// Deltas ≥ 60 ms — late / stalled frames.
    let histAbove60: Int

    // MARK: Init from snapshot

    /// Computes delta stats from the PTS values in `snapshot`.
    ///
    /// Deltas are computed from consecutive values in **arrival order** (not sorted),
    /// so out-of-order or duplicate PTS values remain visible in the histogram.
    init(from snapshot: Diag4KFrameSnapshot) {
        let pts = snapshot.ptsValues
        guard pts.count >= Self.minPtsCountForStats else {
            self = .zero(ptsFps: 0)
            return
        }
        let deltas = Self.consecutiveDeltas(from: pts)
        let histCounts = Self.histogramCounts(from: deltas)
        let ptsSpan = snapshot.lastTimestamp - snapshot.firstTimestamp
        let fps: Double = ptsSpan > 0 ? Double(pts.count - 1) / ptsSpan : 0
        let count = Double(deltas.count)
        let mean = deltas.reduce(0, +) / count
        let variance = deltas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / count
        self.deltaCount = deltas.count
        self.meanMs = mean
        self.minMs = deltas.min() ?? 0
        self.maxMs = deltas.max() ?? 0
        self.stdMs = variance.squareRoot()
        self.ptsFps = fps
        self.histBelow14 = histCounts.below14
        self.hist14to20 = histCounts.hist14to20
        self.hist20to40 = histCounts.hist20to40
        self.hist40to60 = histCounts.hist40to60
        self.histAbove60 = histCounts.above60
    }

    // MARK: Private helpers

    /// Minimum number of PTS values required to compute meaningful delta statistics.
    private static let minPtsCountForStats = 2

    /// Converts an array of PTS values (seconds) into consecutive inter-frame deltas (ms),
    /// preserving arrival order so out-of-order PTS values remain visible.
    private static func consecutiveDeltas(from pts: [Double]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(pts.count - 1)
        var idx = 1
        while idx < pts.count {
            // swiftlint:disable:next no_magic_numbers
            deltas.append((pts[idx] - pts[idx - 1]) * 1000)
            idx += 1
        }
        return deltas
    }

    /// Histogram bucket tuple — counts per cadence range.
    private struct HistCounts {
        /// Deltas below 14 ms (sub-frame for any standard rate).
        var below14 = 0
        /// Deltas in [14, 20) ms — ≈60 fps cadence bucket.
        var hist14to20 = 0
        /// Deltas in [20, 40) ms — ≈30 fps cadence bucket.
        var hist20to40 = 0
        /// Deltas in [40, 60) ms — ≈20 fps cadence bucket.
        var hist40to60 = 0
        /// Deltas ≥ 60 ms — late / stalled frames.
        var above60 = 0
    }

    /// Classifies each delta (ms) into histogram buckets.
    private static func histogramCounts(from deltas: [Double]) -> HistCounts {
        var counts = HistCounts()
        for delta in deltas {
            if delta < DeltaBucket.below {
                counts.below14 += 1
            } else if delta < DeltaBucket.to20 {
                counts.hist14to20 += 1
            } else if delta < DeltaBucket.to40 {
                counts.hist20to40 += 1
            } else if delta < DeltaBucket.to60 {
                counts.hist40to60 += 1
            } else {
                counts.above60 += 1
            }
        }
        return counts
    }

    // MARK: Zero value

    /// Returns a zeroed stats value for degenerate cases (fewer than two PTS samples).
    private static func zero(ptsFps: Double) -> Self {
        Self(
            deltaCount: 0,
            meanMs: 0,
            minMs: 0,
            maxMs: 0,
            stdMs: 0,
            ptsFps: ptsFps,
            histBelow14: 0,
            hist14to20: 0,
            hist20to40: 0,
            hist40to60: 0,
            histAbove60: 0
        )
    }

    // MARK: Memberwise init (used by zero())

    /// Memberwise initialiser used exclusively by `zero(ptsFps:)`.
    private init(
        deltaCount: Int,
        meanMs: Double,
        minMs: Double,
        maxMs: Double,
        stdMs: Double,
        ptsFps: Double,
        histBelow14: Int,
        hist14to20: Int,
        hist20to40: Int,
        hist40to60: Int,
        histAbove60: Int
    ) {
        self.deltaCount = deltaCount
        self.meanMs = meanMs
        self.minMs = minMs
        self.maxMs = maxMs
        self.stdMs = stdMs
        self.ptsFps = ptsFps
        self.histBelow14 = histBelow14
        self.hist14to20 = hist14to20
        self.hist20to40 = hist20to40
        self.hist40to60 = hist40to60
        self.histAbove60 = histAbove60
    }
}

// MARK: - Sample-buffer delegate / frame collector

/// Thread-safe frame collector for the 4K delivery diagnostic.
///
/// `AVCaptureVideoDataOutput` delivers callbacks on a background `DispatchQueue` that is
/// off the main actor. All mutable state is guarded by an `OSAllocatedUnfairLock` so both
/// the callback and the async test body can access it without a data race under Swift 6
/// strict concurrency (`complete` mode, default `MainActor` isolation).
///
/// Marked `@unchecked Sendable` because `NSObject` does not conform to `Sendable`.
/// Thread-safety is guaranteed by the lock — all reads and writes go through `withLock`.
final class Diag4KFrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // MARK: PTS cap

    /// Maximum number of PTS values retained in `State.ptsValues`.
    ///
    /// At 60 fps over a 5-second window ~300 entries are expected; 2 000 comfortably
    /// covers even a hypothetical burst while bounding memory to ~16 KB.
    static let ptsCap = 2000

    // MARK: Locked state

    /// All mutable fields stored as a single struct to allow atomic snapshot reads.
    private struct State {
        /// Number of sample buffers received so far.
        var frameCount = 0
        /// Width of the CVPixelBuffer from the most recent callback.
        var lastWidth: Int32 = 0
        /// Height of the CVPixelBuffer from the most recent callback.
        var lastHeight: Int32 = 0
        /// FourCC string derived from the pixel-format OSType (e.g. "420v").
        var lastFourCC = ""
        /// Presentation timestamp (seconds) of the very first received buffer.
        var firstTimestamp: Double = 0
        /// Presentation timestamp (seconds) of the most recently received buffer.
        var lastTimestamp: Double = 0
        /// PTS (`.seconds`) of each delivered sample buffer, in arrival order.
        ///
        /// Only samples whose `CMSampleBufferGetPresentationTimeStamp` is numeric and
        /// whose `.seconds` value is finite are appended. Capped at `ptsCap` entries.
        var ptsValues: [Double] = []
    }

    /// Lock-guarded mutable state — the project-canonical `OSAllocatedUnfairLock` pattern
    /// (mirrors `FlagBox` in `DualFileOutputStageTests.swift` and inline usages in
    /// `VTServiceRateBenchTests.swift`).
    private let lock = OSAllocatedUnfairLock(initialState: State())

    // MARK: Delegate

    /// Receives each delivered sample buffer off the capture queue and records its metadata.
    ///
    /// `nonisolated` is required: under default `MainActor` isolation an `NSObject` method
    /// would be MainActor-isolated by default, which violates the nonisolated protocol
    /// requirement of `AVCaptureVideoDataOutputSampleBufferDelegate` (warnings-as-errors).
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourCC = Self.fourCCString(from: formatType)
        let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = ptsTime.seconds

        self.lock.withLock { state in
            if state.frameCount == 0 {
                state.firstTimestamp = pts
            }
            state.frameCount += 1
            state.lastWidth = Int32(width)
            state.lastHeight = Int32(height)
            state.lastFourCC = fourCC
            state.lastTimestamp = pts
            // Record PTS for cadence analysis. Guard: only finite values from numeric CMTimes.
            // `ptsTime.isNumeric` mirrors the CMTime contract — indefinite/invalid PTS is excluded.
            if ptsTime.isNumeric, pts.isFinite, state.ptsValues.count < Self.ptsCap {
                state.ptsValues.append(pts)
            }
        }
    }

    // MARK: Snapshot

    /// Returns a point-in-time snapshot of all collected frame statistics, including
    /// a copy of the PTS array for cadence analysis.
    var snapshot: Diag4KFrameSnapshot {
        self.lock.withLock { state in
            Diag4KFrameSnapshot(
                frameCount: state.frameCount,
                lastWidth: state.lastWidth,
                lastHeight: state.lastHeight,
                lastFourCC: state.lastFourCC,
                firstTimestamp: state.firstTimestamp,
                lastTimestamp: state.lastTimestamp,
                ptsValues: state.ptsValues
            )
        }
    }

    // MARK: FourCC helper

    /// Converts a pixel-format `OSType` to a four-character string (e.g. `420v`).
    ///
    /// Uses bit-shifts on each byte — no unsafe pointer access, no force-unwrap.
    /// Big-endian byte order matches the canonical FourCC representation.
    static func fourCCString(from tag: OSType) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar(UInt8((tag >> 24) & 0xFF))), // swiftlint:disable:this no_magic_numbers
            Character(UnicodeScalar(UInt8((tag >> 16) & 0xFF))), // swiftlint:disable:this no_magic_numbers
            Character(UnicodeScalar(UInt8((tag >> 8) & 0xFF))), // swiftlint:disable:this no_magic_numbers
            Character(UnicodeScalar(UInt8(tag & 0xFF))), // swiftlint:disable:this no_magic_numbers
        ]
        return String(chars)
    }
}
