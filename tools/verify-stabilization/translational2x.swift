// Experiment C: Vision TRANSLATIONAL on a 2x upscale of each 1080p frame pair.
// Integer translational in 2x-pixel space -> 0.5px granularity in 1080p coords, from
// the already-proven-robust (global-translation-only, no projective DOF) integer
// estimator. Attacks homographic's weakness (noise/outliers). Each frame is upscaled
// ONCE and cached (serves as curr for pair N-1,N and prev for pair N,N+1).
// CSV: idx,pts,tx,ty (1080p coords, 0.5px),dxT1x,dyT1x (native 1x for ref),visMs.

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Vision

guard CommandLine.arguments.count >= 2 else {
    print("usage: translational2x <video> [csvOut]")
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let csvPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "/tmp/t2x.csv"
let cictx = CIContext(options: [.useSoftwareRenderer: false])
let UW = 3840, UH = 2160

func makePB() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        UW,
        UH,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pb
    )
    return pb!
}

func upscale2x(_ src: CVPixelBuffer) -> CVPixelBuffer {
    let ci = CIImage(cvPixelBuffer: src).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
    let dst = makePB()
    cictx.render(ci, to: dst)
    return dst
}

let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
nonisolated(unsafe) var trackR: AVAssetTrack?
Task { trackR = try? await asset.loadTracks(withMediaType: .video).first
    sem.signal()
}

sem.wait()
guard let track = trackR else {
    print("ERROR: no video track")
    exit(1)
}

let reader: AVAssetReader
do {
    reader = try AVAssetReader(asset: asset)
} catch {
    print("ERROR: AVAssetReader init failed: \(error)")
    print(
        "hint: run unsandboxed — AVAssetReader fails with -11800/-17913 under App Sandbox " +
            "(see README: plain terminal, not a sandbox wrapper or an Xcode scheme with App Sandbox on)"
    )
    exit(1)
}

let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
])
rout.alwaysCopiesSampleData = false
reader.add(rout)
reader.startReading()

var prev1x: CVPixelBuffer?
var prev2x: CVPixelBuffer?
var rows = "idx,pts,tx,ty,dxT1x,dyT1x,visMs\n"
var lats: [Double] = []
var idx = 0
var nonIntCount = 0 // sanity: 2x-space tx should be integer

while let sb = rout.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    let cur2x = upscale2x(pb)
    if let p1 = prev1x, let p2 = prev2x {
        // native 1x translational (reference)
        var dx1 = 0.0, dy1 = 0.0
        let t1 = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pb)
        let h1 = VNImageRequestHandler(cvPixelBuffer: p1, options: [:])
        if (try? h1.perform([t1])) != nil, let o1 = t1.results?.first as? VNImageTranslationAlignmentObservation {
            dx1 = Double(o1.alignmentTransform.tx)
            dy1 = Double(o1.alignmentTransform.ty)
        }
        // 2x translational (timed = the estimation only, not the upscale)
        let t2 = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: cur2x)
        let h2 = VNImageRequestHandler(cvPixelBuffer: p2, options: [:])
        let t0 = DispatchTime.now()
        let ok = (try? h2.perform([t2])) != nil
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        if ok, let o2 = t2.results?.first as? VNImageTranslationAlignmentObservation {
            let tx2 = Double(o2.alignmentTransform.tx), ty2 = Double(o2.alignmentTransform.ty)
            if abs(tx2 - tx2.rounded()) > 0.01 || abs(ty2 - ty2.rounded()) > 0.01 { nonIntCount += 1 }
            let tx = tx2 / 2, ty = ty2 / 2 // back to 1080p coords -> 0.5px granularity
            lats.append(ms)
            rows += "\(idx),\(String(format: "%.3f", pts)),\(String(format: "%.4f", tx)),\(String(format: "%.4f", ty)),\(String(format: "%.4f", dx1)),\(String(format: "%.4f", dy1)),\(String(format: "%.3f", ms))\n"
        }
    }
    prev1x = pb
    prev2x = cur2x
    idx += 1
}

try? rows.write(toFile: csvPath, atomically: true, encoding: .utf8)

func pct(_ s: [Double], _ p: Double) -> Double {
    s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
}

let warm = lats.count > 30 ? Array(lats[30...]).sorted() : lats.sorted()
print("=== translational @2x (0.5px) ===")
print("pairs=\(lats.count)  2x-space non-integer tx/ty count=\(nonIntCount) (expect 0)")
print(String(
    format: "vision-only latency ms (warmup>30 excl): p50=%.3f p95=%.3f max=%.3f",
    pct(warm, 0.5),
    pct(warm, 0.95),
    warm.last ?? 0
))
print("csv: \(csvPath)")
