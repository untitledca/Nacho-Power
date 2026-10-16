import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

func fourCC(_ value: FourCharCode) -> String {
    let scalars = [24,16,8,0].map { UnicodeScalar(Int((value >> $0) & 0xff))! }
    return String(String.UnicodeScalarView(scalars))
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let names = CommandLine.arguments.count > 3 ? Array(CommandLine.arguments.dropFirst(3)) : ["intro", "loop"]
for name in names {
    let asset = AVURLAsset(url: directory.appendingPathComponent("\(name).mov"))
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    guard let track = asset.tracks(withMediaType: .video).first else { fatalError("No video \(name)") }
    let desc = track.formatDescriptions.first as! CMFormatDescription
    print("\(name): \(track.naturalSize), \(track.nominalFrameRate) fps, \(asset.duration.seconds) sec, codec \(fourCC(CMFormatDescriptionGetMediaSubType(desc))), transform \(track.preferredTransform), audio tracks \(asset.tracks(withMediaType: .audio).count)")
    print("format extensions: \(CMFormatDescriptionGetExtensions(desc))")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_64ARGB])
    reader.add(output)
    reader.startReading()
    var frame = 0
    let sampleFrames = Set([0, Int(asset.duration.seconds * Double(track.nominalFrameRate) / 2), max(0, Int(asset.duration.seconds * Double(track.nominalFrameRate)) - 1)])
    while let sample = output.copyNextSampleBuffer() {
        if sampleFrames.contains(frame), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var transparent = 0, translucent = 0, opaque = 0, minimumAlpha = 65535, maximumAlpha = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let alpha = (Int(bytes[y * stride + x * 8]) << 8) | Int(bytes[y * stride + x * 8 + 1])
                    minimumAlpha = min(minimumAlpha, alpha); maximumAlpha = max(maximumAlpha, alpha)
                    if alpha == 0 { transparent += 1 }
                    else {
                        if alpha == 65535 { opaque += 1 } else { translucent += 1 }
                        if alpha > 5000 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) }
                    }
                }
            }
            let cornerBytes = Array(UnsafeBufferPointer(start: bytes, count: 8))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            print("  frame \(frame): alpha0 \(transparent), partial \(translucent), opaque \(opaque), alpha range \(minimumAlpha)...\(maximumAlpha), corner bytes \(cornerBytes), content box \(minX),\(minY)→\(maxX),\(maxY)")
            // Core Image does not render every 64ARGB decoder buffer format.
            // AVAssetImageGenerator preserves native alpha when producing a CGImage.
            let cgImage = try imageGenerator.copyCGImage(at: CMSampleBufferGetPresentationTimeStamp(sample), actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: outputDir.appendingPathComponent("\(name)-\(frame).png"))
        }
        frame += 1
    }
    print("  total frames \(frame), reader status \(reader.status.rawValue), error \(String(describing: reader.error))")
}
