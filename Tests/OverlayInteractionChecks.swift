import AppKit
import AVFoundation

/// No windows or event monitors are created. The optional asset directory also
/// verifies actual HEVC-alpha buffers through the same native player-output API.
@main
private struct OverlayInteractionChecks {
    @MainActor static func main() async {
        let width = 32, height = 24, rowBytes = 144
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        func bounds(step: Int = 1) -> CGRect? {
            pixels.withUnsafeBytes {
                OverlayCatBounds.alphaBounds(bgra: $0.baseAddress!, width: width,
                    height: height, bytesPerRow: rowBytes, sampleStep: step)
            }
        }
        check(bounds() == nil, "An empty frame has no click target")
        // A known asymmetric silhouette at the upper-left tests channel order,
        // row padding, and the image-to-AppKit vertical coordinate conversion.
        for y in 2..<10 { for x in 4..<16 { pixels[y * rowBytes + x * 4 + 3] = 255 } }
        let result = bounds()!
        check(close(result.minX, 3.0 / 32) && close(result.maxX, 17.0 / 32), "Alpha X extent, including a one-sample edge margin")
        check(close(result.minY, 13.0 / 24) && close(result.maxY, 23.0 / 24), "Top-down alpha rows map to unflipped AppKit Y")
        let sparse = bounds(step: 4)!
        check(sparse.minX <= 4.0 / 32 && sparse.maxX >= 16.0 / 32 &&
              sparse.minY <= 14.0 / 24 && sparse.maxY >= 22.0 / 24,
              "Sparse sampling expands its edge to contain the original silhouette")
        let screen = CGRect(x: -1920, y: 380, width: 1920, height: 1080)
        let target = OverlayCatBounds.screenRect(normalizedBounds: result, videoRect: screen)!
        check(target.minX < -1000 && target.minY > screen.midY && screen.contains(target),
              "External-display coordinates retain orientation and stay within the video")
        let portrait = OverlayCanvasLayout.frame(in: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                                                 aspect: 16.0 / 9.0, side: .right, fullScreen: true)
        let portraitTarget = OverlayCatBounds.screenRect(normalizedBounds: result, videoRect: portrait)!
        check(portrait.contains(portraitTarget) && portraitTarget.maxY < 608,
              "A portrait display's transparent area above the video never becomes interactive")
        let clipped = OverlayCatBounds.screenRect(normalizedBounds: CGRect(x: -0.2, y: -0.2, width: 1.4, height: 1.4), videoRect: screen)
        check(clipped == nil, "Malformed bounds cannot make the entire video interactive")
        check(OverlayCatBounds.screenRect(normalizedBounds: CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2), videoRect: screen) == nil,
              "Nonfinite origins never create an input panel")
        check(OverlayCatBounds.screenRect(normalizedBounds: .zero, videoRect: screen) == nil,
              "Empty geometry never creates an input panel")
        check(OverlayCatBounds.screenRect(normalizedBounds: result, videoRect: .infinite) == nil,
              "Invalid geometry never creates an input panel")
        for y in 0..<height { for x in 0..<width { pixels[y * rowBytes + x * 4 + 3] = 255 } }
        check(bounds() == nil, "A decoder that drops transparency cannot block the whole video")
        pixels = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 2..<10 { for x in 4..<16 { pixels[y * rowBytes + x * 4] = 255 } }
        check(bounds() == nil, "Opaque-looking RGB with zero alpha cannot create a target")
        for y in 2..<10 { for x in 4..<16 { pixels[y * rowBytes + x * 4 + 3] = 32 } }
        check(bounds() == nil, "Faint compression residue does not make the background interactive")
        print("PASS nonvisual click-target geometry: alpha, padding, orientation, scaling, external displays, transparent backgrounds, and invalid buffers")

        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            for clip in OverlayVideoSide.allCases.flatMap(\.clips) {
                await verifyDecodedAlpha(directory.appendingPathComponent(clip + ".mov"))
            }
        }
    }

    @MainActor private static func verifyDecodedAlpha(_ url: URL) async {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.suppressesPlayerRendering = false
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let duration = (try? await item.asset.load(.duration).seconds) ?? 0
        check(duration > 0, "Bundled clip has a duration")
        await player.seek(to: CMTime(seconds: duration * 0.65, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        var found: CGRect?
        var scanMilliseconds = 0.0
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let time = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            check(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, "Native video output supplies BGRA")
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let started = CACurrentMediaTime()
                found = OverlayCatBounds.alphaBounds(bgra: base, width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
                scanMilliseconds = (CACurrentMediaTime() - started) * 1000
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            if found != nil { break }
        }
        player.pause()
        item.remove(output)
        check(found != nil, "\(url.lastPathComponent) has a bounded cat silhouette in its actual playback output")
        check(found!.width * found!.height < 0.85, "\(url.lastPathComponent) target remains much smaller than its canvas")
        print("PASS native alpha output \(url.lastPathComponent): bounds=\(found!), scan=\(String(format: "%.2f", scanMilliseconds)) ms")
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.00001 }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
}
