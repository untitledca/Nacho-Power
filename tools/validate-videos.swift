import Foundation
import AVFoundation
import CoreVideo

struct AlphaSample: Codable {
    let time: Double
    let minimumAlpha: Int
    let maximumAlpha: Int
    let transparentFraction: Double
    let cornerAlpha: Int
}
struct VideoReport: Codable {
    let file: String
    let width: Int
    let height: Int
    let frameRate: Float
    let seconds: Double
    let alphaMetadata: Bool
    let samples: [AlphaSample]
    let warning: String?
}
struct ValidationReport: Codable {
    let generatedAt: String
    let sourceDirectory: String
    let validForTransparentOverlay: Bool
    let videos: [VideoReport]
    let warnings: [String]
}
@main struct ValidateVideos {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var reports: [VideoReport] = []
        for name in ["intro", "middle", "outro"] {
            let asset = AVURLAsset(url: folder.appendingPathComponent("\(name).mov"))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "EcoFlowCatValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track in \(name).mov"])
            }
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration).seconds
            let descriptions = try await track.load(.formatDescriptions)
            let alphaMetadata = descriptions.contains { format in
                guard let raw = CMFormatDescriptionGetExtensions(format) else { return false }
                let extensions = raw as NSDictionary
                return (extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool) == true ||
                       (extensions[kCMFormatDescriptionExtension_Depth] as? Int) == 32
            }
            var samples: [AlphaSample] = []
            for seconds in [0.0, duration / 2.0, max(0, duration - 1.0 / Double(rate))] {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                               duration: CMTime(seconds: 1.0 / Double(rate), preferredTimescale: 600))
                let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64ARGB])
                reader.add(trackOutput)
                guard reader.startReading() else { throw reader.error! }
                guard let sample = trackOutput.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    if let error = reader.error { throw error }
                    continue
                }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                var minAlpha = 65535, maxAlpha = 0, transparent = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let alpha = (Int(bytes[y * stride + x * 8]) << 8) | Int(bytes[y * stride + x * 8 + 1])
                        minAlpha = min(minAlpha, alpha); maxAlpha = max(maxAlpha, alpha)
                        if alpha < 512 { transparent += 1 }
                    }
                }
                let corner = (Int(bytes[0]) << 8) | Int(bytes[1])
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                samples.append(AlphaSample(time: seconds, minimumAlpha: minAlpha, maximumAlpha: maxAlpha,
                                           transparentFraction: Double(transparent) / Double(width * height), cornerAlpha: corner))
                reader.cancelReading()
            }
            let hasTransparentBackground = samples.contains { $0.transparentFraction > 0.10 }
            let warning: String? = !alphaMetadata ? "\(name).mov has no alpha channel and has an opaque background." :
                !hasTransparentBackground ? "\(name).mov has an alpha channel, but the sampled black background is opaque. Re-export with a transparent background." : nil
            reports.append(VideoReport(file: "\(name).mov", width: Int(size.width), height: Int(size.height), frameRate: rate,
                                       seconds: duration, alphaMetadata: alphaMetadata, samples: samples, warning: warning))
        }
        let warnings = reports.compactMap(\.warning)
        let report = ValidationReport(generatedAt: ISO8601DateFormatter().string(from: Date()), sourceDirectory: folder.path,
                                      validForTransparentOverlay: warnings.isEmpty, videos: reports, warnings: warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
        for warning in warnings { print(warning) }
        print("Wrote \(output.path), transparent overlay valid: \(warnings.isEmpty)")
    }
}
