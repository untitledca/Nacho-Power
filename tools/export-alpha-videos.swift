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
        for name in ["intro", "loop"] {
            let input = source.appendingPathComponent("\(name).mov")
            let output = destination.appendingPathComponent("\(name).mov")
            let temporary = destination.appendingPathComponent(".\(name)-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let asset = AVURLAsset(url: input)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let descriptions = try await tracks.first?.load(.formatDescriptions) ?? []
            let containsAlpha = descriptions.contains { format in
                guard let rawExtensions = CMFormatDescriptionGetExtensions(format) else { return false }
                let extensions = rawExtensions as NSDictionary
                return (extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool) == true || (extensions[kCMFormatDescriptionExtension_Depth] as? Int) == 32
            }
            guard containsAlpha else {
                throw NSError(domain: "EcoFlowCatExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name).mov needs a transparent alpha channel."])
            }
            let preset = AVAssetExportPresetHEVC1920x1080WithAlpha
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw NSError(domain: "EcoFlowCatExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "HEVC with alpha export unavailable for \(input.path)"])
            }
            exporter.shouldOptimizeForNetworkUse = false
            try await exporter.export(to: temporary, as: AVFileType.mov)
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("\(name).mov: \(bytes) bytes, HEVC export complete (source alpha metadata: \(containsAlpha))")
        }
    }
}
