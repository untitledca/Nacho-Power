import AppKit
import AVFoundation
import CoreVideo
import VideoToolbox

@main struct GenerateAlphaFixture {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["intro", "loop"] {
            let url = folder.appendingPathComponent("\(name).mov")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let width = 640, height = 360, fps = 24
            let frames = name == "loop" ? 24 : 48
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0]
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error! }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<frames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                var optionalBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &optionalBuffer) == kCVReturnSuccess,
                      let buffer = optionalBuffer else { fatalError("Pixel buffer unavailable") }
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                let progress = Double(frame) / Double(frames - 1)
                let scale = name == "intro" ? progress : 1
                let bob = name == "loop" ? sin(Double(frame) / Double(frames) * 2 * .pi) * 15 : 0
                let radius = 100 * scale
                context.setFillColor(NSColor.systemPurple.cgColor)
                context.fillEllipse(in: CGRect(x: 320 - radius, y: 180 - radius + bob, width: 2 * radius, height: 2 * radius))
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: CGRect(x: 278, y: 202 + bob, width: 20 * scale, height: 20 * scale))
                context.fillEllipse(in: CGRect(x: 337, y: 202 + bob, width: 20 * scale, height: 20 * scale))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                    throw writer.error!
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error! }
            print("\(url.path): known transparent HEVC alpha fixture written")
        }
    }
}
