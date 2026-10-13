import Foundation
import AVFoundation

@main struct ExportAlphaVideos {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: export-alpha-videos INPUT_DIRECTORY OUTPUT_DIRECTORY")
            return
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["intro", "middle", "outro"] {
            let input = source.appendingPathComponent("\(name).mov")
            let output = destination.appendingPathComponent("\(name).mov")
            let asset = AVURLAsset(url: input)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let descriptions = try await tracks.first?.load(.formatDescriptions) ?? []
            let containsAlpha = descriptions.contains { format in
                guard let rawExtensions = CMFormatDescriptionGetExtensions(format) else { return false }
                let extensions = rawExtensions as NSDictionary
                return (extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool) == true || (extensions[kCMFormatDescriptionExtension_Depth] as? Int) == 32
            }
            let preset = containsAlpha ? AVAssetExportPresetHEVC1920x1080WithAlpha : AVAssetExportPresetHEVC1920x1080
            if !containsAlpha { print("Warning: \(name).mov has no alpha channel. Exported derivative will retain its opaque background.") }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw NSError(domain: "EcoFlowCatExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "HEVC with alpha export unavailable for \(input.path)"])
            }
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            exporter.shouldOptimizeForNetworkUse = false
            try await exporter.export(to: output, as: AVFileType.mov)
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("\(name).mov: \(bytes) bytes, HEVC export complete (source alpha metadata: \(containsAlpha))")
        }
    }
}
