import AppKit
import Foundation

/// Pure geometry checks only. This executable creates no NSApplication,
/// overlay controller, player, or window.
@main
private struct OverlayLayoutChecks {
    @MainActor static func main() {
        let videoAspect: CGFloat = 16.0 / 9.0
        let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)

        for side in OverlayVideoSide.allCases {
            checkFrame(OverlayCanvasLayout.frame(in: laptop, aspect: videoAspect, side: side, fullScreen: true),
                       equals: CGRect(x: 0, y: 0, width: 1728, height: 972),
                       "The connected laptop display fits the full video above its bottom edge")
            checkFrame(OverlayCanvasLayout.frame(in: portrait, aspect: videoAspect, side: side, fullScreen: true),
                       equals: CGRect(x: 0, y: 0, width: 1080, height: 607.5),
                       "Portrait displays retain the whole video canvas without enlarging or cropping the cat")
            checkFrame(OverlayCanvasLayout.frame(in: landscape, aspect: videoAspect, side: side, fullScreen: true),
                       equals: landscape,
                       "A matching landscape display uses its complete bounds")
            checkFrame(OverlayCanvasLayout.frame(in: ultrawide, aspect: videoAspect, side: side, fullScreen: true),
                       equals: CGRect(x: side == .left ? 0 : 880, y: 0, width: 2560, height: 1440),
                       "Ultrawide displays anchor the fitted video to the chosen entry edge")
        }

        let offsetBounds = CGRect(x: -40, y: -200, width: 3440, height: 1440)
        checkFrame(OverlayCanvasLayout.frame(in: offsetBounds, aspect: videoAspect, side: .right, fullScreen: true),
                   equals: CGRect(x: 840, y: -200, width: 2560, height: 1440),
                   "Nonzero bounds origins are preserved")

        for bounds in [portrait, landscape, ultrawide, offsetBounds,
                       CGRect(x: 0, y: 0, width: 320, height: 180)] {
            for side in OverlayVideoSide.allCases {
                checkFrame(OverlayCanvasLayout.frame(in: bounds, aspect: videoAspect, side: side, fullScreen: false),
                           equals: bounds, "Corner mode retains its existing canvas bounds")
            }
        }

        // These assertions describe containment and preserved proportions,
        // independent of the implementation's choice of width/height formula.
        let aspects: [CGFloat] = [16.0 / 9.0, 4.0 / 3.0, 1.0, 9.0 / 16.0]
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080),
                     CGSize(width: 3440, height: 1440), CGSize(width: 1024, height: 1024),
                     CGSize(width: 768, height: 1366), CGSize(width: 6016, height: 3384)] {
            let bounds = CGRect(origin: CGPoint(x: -125, y: 73), size: size)
            for aspect in aspects {
                for side in OverlayVideoSide.allCases {
                    let result = OverlayCanvasLayout.frame(in: bounds, aspect: aspect, side: side, fullScreen: true)
                    check(result.width > 0 && result.height > 0 && finite(result), "Fitted canvas has finite positive dimensions")
                    check(close(result.width / result.height, aspect), "Fitting never stretches the video's proportions")
                    check(result.minX >= bounds.minX - 0.00001 && result.maxX <= bounds.maxX + 0.00001 &&
                          result.minY >= bounds.minY - 0.00001 && result.maxY <= bounds.maxY + 0.00001,
                          "The entire video canvas remains inside the display bounds")
                    check(close(result.minY, bounds.minY), "The cat remains anchored to the bottom of the display")
                    check(close(side == .left ? result.minX : result.maxX,
                                side == .left ? bounds.minX : bounds.maxX),
                          "The canvas remains anchored to the selected entrance edge")
                    check(close(result.width, bounds.width) || close(result.height, bounds.height),
                          "Fitting uses the largest uncropped canvas that fits")
                }
            }
        }

        let invalidAspects: [CGFloat] = [0, -1, .nan, .infinity, -.infinity]
        for invalidAspect in invalidAspects {
            checkFrame(OverlayCanvasLayout.frame(in: portrait, aspect: invalidAspect, side: .right, fullScreen: true),
                       equals: CGRect(x: 0, y: 0, width: 1080, height: 607.5),
                       "Invalid metadata uses a finite 16:9 fallback")
        }
        print("PASS nonvisual overlay layout: portrait/landscape/ultrawide, entry edges, containment, proportions, corner mode, and invalid-aspect fallback")
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.00001 }

    private static func checkFrame(_ actual: CGRect, equals expected: CGRect, _ message: String) {
        check(finite(actual) && close(actual.minX, expected.minX) && close(actual.minY, expected.minY) &&
              close(actual.width, expected.width) && close(actual.height, expected.height),
              "\(message): expected \(expected), got \(actual)")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
