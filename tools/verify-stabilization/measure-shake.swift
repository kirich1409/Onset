import AVFoundation
import Foundation
import Vision

guard CommandLine.arguments.count >= 2 else {
    print("usage: measure-shake <video> [csvOut]")
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let csvPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "/tmp/shake.csv"

let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
nonisolated(unsafe) var trackResult: AVAssetTrack?
Task {
    trackResult = try? await asset.loadTracks(withMediaType: .video).first
    sem.signal()
}

sem.wait()
guard let track = trackResult else {
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

let settings: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
]
let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
output.alwaysCopiesSampleData = false
reader.add(output)
reader.startReading()

var prevSB: CMSampleBuffer?
var csv = "idx,pts,dx,dy,cumx,cumy,ms\n"
var pts_: [Double] = []
var dxs: [Double] = []
var dys: [Double] = []
var lats: [Double] = []
var cumsX: [Double] = []
var cumsY: [Double] = []
var cumX = 0.0
var cumY = 0.0
var idx = 0

while let sb = output.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    if let p = prevSB, let prevPB = CMSampleBufferGetImageBuffer(p) {
        let req = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pb)
        let handler = VNImageRequestHandler(cvPixelBuffer: prevPB, options: [:])
        let t0 = DispatchTime.now()
        do {
            try handler.perform([req])
        } catch {
            print("WARN: registration failed at frame \(idx): \(error)")
            prevSB = sb
            idx += 1
            continue
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        if let obs = req.results?.first {
            let tr = obs.alignmentTransform
            let dx = Double(tr.tx)
            let dy = Double(tr.ty)
            cumX += dx
            cumY += dy
            pts_.append(pts)
            dxs.append(dx)
            dys.append(dy)
            lats.append(ms)
            cumsX.append(cumX)
            cumsY.append(cumY)
            csv += "\(idx),\(String(format: "%.3f", pts)),\(dx),\(dy),\(String(format: "%.3f", cumX)),\(String(format: "%.3f", cumY)),\(String(format: "%.2f", ms))\n"
        }
    }
    prevSB = sb
    idx += 1
}

try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)

func pct(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let i = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[i]
}

let n = dxs.count
let duration = (pts_.last ?? 0) - (pts_.first ?? 0)
let absDx = dxs.map(abs).sorted()
let absDy = dys.map(abs).sorted()
let mags = zip(dxs, dys).map { ($0 * $0 + $1 * $1).squareRoot() }.sorted()
let latsSorted = lats.sorted()

// Pairs that are effectively static (hold-repeat duplicates or true stillness).
let staticEps = 0.05
let staticPairs = zip(dxs, dys).count(where: { abs($0) < staticEps && abs($1) < staticEps })

/// Moving pairs only — the shake signal.
let movingMags = zip(dxs, dys).filter { abs($0) >= staticEps || abs($1) >= staticEps }
    .map { ($0 * $0 + $1 * $1).squareRoot() }.sorted()

// Lock-to-reference crop driver: deviation of cumulative position from a
// trailing 2-second rolling mean.
let fps = duration > 0 ? Double(n) / duration : 60
let win = max(1, Int(fps * 2.0))
var devs: [Double] = []
for i in 0..<n {
    let lo = max(0, i - win)
    let cnt = Double(i - lo + 1)
    let mx = cumsX[lo...i].reduce(0, +) / cnt
    let my = cumsY[lo...i].reduce(0, +) / cnt
    let dev = ((cumsX[i] - mx) * (cumsX[i] - mx) + (cumsY[i] - my) * (cumsY[i] - my)).squareRoot()
    devs.append(dev)
}

let devsSorted = devs.sorted()

// Oscillation frequency estimate: sign changes of dx among moving pairs.
var signChanges = 0
var lastSign = 0
for dx in dxs where abs(dx) >= staticEps {
    let s = dx > 0 ? 1 : -1
    if lastSign != 0, s != lastSign { signChanges += 1 }
    lastSign = s
}

let freq = duration > 0 ? Double(signChanges) / (2.0 * duration) : 0

// Trajectory range (drift + oscillation envelope).
let rangeX = (cumsX.max() ?? 0) - (cumsX.min() ?? 0)
let rangeY = (cumsY.max() ?? 0) - (cumsY.min() ?? 0)

print("=== shake measurement ===")
print("pairs=\(n) duration=\(String(format: "%.1f", duration))s effFps=\(String(format: "%.1f", fps))")
print(
    "staticPairs=\(staticPairs) (\(String(format: "%.1f", 100.0 * Double(staticPairs) / Double(max(1, n))))%) movingPairs=\(n - staticPairs)"
)
print(
    "perFrame |dx| px: p50=\(String(format: "%.2f", pct(absDx, 0.5))) p95=\(String(format: "%.2f", pct(absDx, 0.95))) p99=\(String(format: "%.2f", pct(absDx, 0.99))) max=\(String(format: "%.2f", absDx.last ?? 0))"
)
print(
    "perFrame |dy| px: p50=\(String(format: "%.2f", pct(absDy, 0.5))) p95=\(String(format: "%.2f", pct(absDy, 0.95))) p99=\(String(format: "%.2f", pct(absDy, 0.99))) max=\(String(format: "%.2f", absDy.last ?? 0))"
)
print(
    "perFrame magnitude px (all): p50=\(String(format: "%.2f", pct(mags, 0.5))) p95=\(String(format: "%.2f", pct(mags, 0.95))) max=\(String(format: "%.2f", mags.last ?? 0))"
)
print(
    "perFrame magnitude px (moving only): p50=\(String(format: "%.2f", pct(movingMags, 0.5))) p95=\(String(format: "%.2f", pct(movingMags, 0.95))) max=\(String(format: "%.2f", movingMags.last ?? 0))"
)
print(
    "lock-to-ref deviation px (2s rolling ref): p50=\(String(format: "%.2f", pct(devsSorted, 0.5))) p95=\(String(format: "%.2f", pct(devsSorted, 0.95))) p99=\(String(format: "%.2f", pct(devsSorted, 0.99))) max=\(String(format: "%.2f", devsSorted.last ?? 0))"
)
print("trajectory range px: x=\(String(format: "%.2f", rangeX)) y=\(String(format: "%.2f", rangeY))")
print("oscillation freq est: \(String(format: "%.1f", freq)) Hz (sign changes on moving dx)")
print(
    "Vision registration latency ms: p50=\(String(format: "%.2f", pct(latsSorted, 0.5))) p95=\(String(format: "%.2f", pct(latsSorted, 0.95))) max=\(String(format: "%.2f", latsSorted.last ?? 0))"
)
print("csv: \(csvPath)")
