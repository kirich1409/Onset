import AVFoundation

// MARK: - CameraSource audio output settings builder

extension CameraSource {
    /// 32-bit float depth for the pinned LPCM capture format (matches FileWriter's AAC target).
    private static let lpcmBitDepth = 32

    /// Builds the `audioSettings` dictionary for `AVCaptureAudioDataOutput`.
    ///
    /// A fixed LPCM format is mandated because `AVCaptureAudioDataOutput` with `audioSettings = nil`
    /// delivers buffers in the device's native transport format (e.g. int16 interleaved stereo for
    /// USB microphones such as the MX Brio), then switches mid-stream to float32 non-interleaved
    /// once CoreAudio's channel routing is established. `AVAssetWriterInput` (AAC) configures its
    /// internal converter on the first buffer; a mid-stream layout change causes the converter to
    /// fault with -12737 (ArrayTooSmall), killing both writers (#105).
    ///
    /// Pinning to float32 interleaved LPCM at the capture layer prevents the format switch entirely:
    /// CoreAudio normalises to the requested format once, before any buffer reaches the pipeline.
    ///
    /// Parameters are sourced from `RecordingConfiguration` (the same values `FileWriter` uses for
    /// its AAC encoder target) so the capture format and the mux format remain consistent
    /// by construction.
    nonisolated static func audioOutputSettings(
        sampleRate: Double,
        channelCount: Int
    )
    -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: self.lpcmBitDepth,
            AVLinearPCMIsFloatKey: true,
            // Interleaved (false = non-interleaved/planar). Keeping interleaved even for mono:
            // consistent across stereo post-MVP, and avoids the int16-planar mid-stream switch.
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}
