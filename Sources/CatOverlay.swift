import AppKit
import AVFoundation
import QuartzCore

/// The cat never takes keyboard focus or intercepts clicks, including inside its image.
enum OverlayCorner: String, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}

private final class CatOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CatVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.isOpaque = false
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Uses AVFoundation's native video layers and decoder, with no frame-copy timer.
/// Bundle assets should be HEVC with alpha, converted once from the user's ProRes masters.
@MainActor
final class CatOverlayController {
    enum PlaybackState: String { case hidden, intro, middle, outro }

    var onPlaybackError: ((String) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onOutroFinished: (() -> Void)?
    private(set) var playbackState: PlaybackState = .hidden
    var isVisible: Bool { panel.isVisible }
    var isPreviewing: Bool { previewLoopTarget != nil }

    private let panel: CatOverlayPanel
    private let videoView: CatVideoView
    private let player = AVQueuePlayer()
    private let assets: [String: AVURLAsset]
    private var looper: AVPlayerLooper?
    private var introItem: AVPlayerItem?
    private var outroItem: AVPlayerItem?
    private var statusObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var previewLoopTarget: Int?
    private var previewTimeObserver: Any?
    private var generation = 0
    private var width: CGFloat = 320
    private var corner: OverlayCorner = .bottomRight
    private var screenIndex = 0
    private var fullScreen = true
    private var aspectRatio: CGFloat = 16.0 / 9.0

    init(assetDirectory: URL) {
        assets = Dictionary(uniqueKeysWithValues: ["intro", "middle", "outro"].map {
            ($0, AVURLAsset(url: assetDirectory.appendingPathComponent("\($0).mov")))
        })
        videoView = CatVideoView(frame: .zero)
        panel = CatOverlayPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "EcoFlow Cat Overlay"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if #available(macOS 14.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.contentView = videoView
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        videoView.playerLayer.player = player

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.itemEnded(note.object as? AVPlayerItem) }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                  object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, self.owns(item) else { return }
                self.failed("Unable to play cat video: \(item.error?.localizedDescription ?? "playback stopped unexpectedly")")
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }
        positionPanel()
        if let asset = assets["middle"] {
            Task { [weak self] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let size = try? await track.load(.naturalSize), size.height > 0 else { return }
                self?.aspectRatio = size.width / size.height
                self?.positionPanel()
            }
        }
    }

    func updateAppearance(width: CGFloat, corner: OverlayCorner, screenIndex: Int = 0, fullScreen: Bool = true) {
        self.width = min(1000, max(160, width))
        self.corner = corner
        self.screenIndex = screenIndex
        self.fullScreen = fullScreen
        positionPanel()
    }

    /// Idempotent while a real reminder is already playing.
    func startReminder() {
        guard playbackState == .hidden || playbackState == .outro || isPreviewing else { return }
        start(previewLoops: nil)
    }

    /// Plays intro, two complete middle loops, and outro without changing reminder settings.
    func preview() { start(previewLoops: 2) }

    /// Charging resumes: interrupt intro or middle promptly and play the outro once.
    func finishReminder() {
        guard playbackState != .hidden, playbackState != .outro else { return }
        stopPreviewObserver()
        playbackState = .outro
        looper?.disableLooping()
        looper = nil
        let current = player.currentItem
        for item in player.items() where item !== current { player.remove(item) }
        let item = makeItem("outro")
        outroItem = item
        player.insert(item, after: current)
        if current != nil { player.advanceToNextItem() }
        player.play()
    }

    func hide() {
        generation += 1
        stopPreviewObserver()
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        statusObservations.removeAll()
        introItem = nil
        outroItem = nil
        previewLoopTarget = nil
        playbackState = .hidden
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?(false) }
    }

    /// Used by the smoke test to check the actual AppKit window configuration.
    var diagnostics: [String: Any] {
        ["visible": panel.isVisible,
         "ignoresMouseEvents": panel.ignoresMouseEvents,
         "opaque": panel.isOpaque,
         "canBecomeKey": panel.canBecomeKey,
         "canBecomeMain": panel.canBecomeMain,
         "movable": panel.isMovable,
         "allSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
         "fullscreenAuxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary),
         "allApplications": panel.collectionBehavior.rawValue & (1 << 18) != 0,
         "playbackState": playbackState.rawValue,
         "fullScreen": fullScreen,
         "screenIndex": screenIndex,
         "videoReady": videoView.playerLayer.isReadyForDisplay,
         "playerStatus": player.status.rawValue,
         "windowFrame": NSStringFromRect(panel.frame),
         "muted": player.isMuted,
         "loopCount": looper?.loopCount ?? 0]
    }

    private func start(previewLoops: Int?) {
        hide()
        guard ["intro", "middle", "outro"].allSatisfy({ name in
            assets[name].map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
        }) else {
            onPlaybackError?("Cat videos are missing. Expected intro.mov, middle.mov and outro.mov in the app's Resources folder.")
            return
        }
        previewLoopTarget = previewLoops
        playbackState = .intro
        let intro = makeItem("intro")
        introItem = intro
        player.insert(intro, after: nil)
        let middle = makeItem("middle")
        looper = AVPlayerLooper(player: player, templateItem: middle,
                                timeRange: .invalid,
                                existingItemsOrdering: .loopingItemsFollowExistingItems)
        for item in looper?.loopingPlayerItems ?? [] { observeStatus(item) }
        if let target = previewLoopTarget {
            // Queue changes must occur outside AVPlayerItemDidPlayToEndTime: AVQueuePlayer
            // is still advancing at that notification and can otherwise skip the outro.
            previewTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.playbackState == .middle,
                          let count = self.looper?.loopCount, count >= target else { return }
                    self.finishReminder()
                }
            }
        }
        positionPanel()
        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
        player.play()
    }

    private func makeItem(_ name: String) -> AVPlayerItem {
        let item = AVPlayerItem(asset: assets[name]!)
        item.preferredForwardBufferDuration = 1
        observeStatus(item)
        return item
    }

    private func observeStatus(_ item: AVPlayerItem) {
        let expectedGeneration = generation
        statusObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == expectedGeneration, item.status == .failed else { return }
                self.failed("Unable to decode cat video: \(item.error?.localizedDescription ?? "unsupported video format")")
            }
        })
    }

    private func owns(_ item: AVPlayerItem) -> Bool {
        item === introItem || item === outroItem || player.items().contains(where: { $0 === item }) ||
        (looper?.loopingPlayerItems.contains(where: { $0 === item }) ?? false)
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item else { return }
        if item === outroItem, playbackState == .outro {
            hide()
            onOutroFinished?()
        } else if item === introItem, playbackState == .intro {
            playbackState = .middle
        }
    }

    private func stopPreviewObserver() {
        if let observer = previewTimeObserver {
            player.removeTimeObserver(observer)
            previewTimeObserver = nil
        }
        previewLoopTarget = nil
    }

    private func failed(_ message: String) {
        hide()
        onPlaybackError?(message)
    }

    private func positionPanel() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.indices.contains(screenIndex) ? screens[screenIndex] : screens[0]
        videoView.playerLayer.videoGravity = fullScreen ? .resizeAspectFill : .resizeAspect
        if fullScreen {
            panel.setFrame(screen.frame, display: true)
            videoView.needsLayout = true
            return
        }
        let available = screen.visibleFrame
        let displayWidth = min(width, available.width - 32)
        let displayHeight = displayWidth / aspectRatio
        let inset: CGFloat = 16
        let left = corner == .bottomLeft || corner == .topLeft
        let bottom = corner == .bottomLeft || corner == .bottomRight
        let x = left ? available.minX + inset : available.maxX - displayWidth - inset
        let y = bottom ? available.minY + inset : available.maxY - displayHeight - inset
        panel.setFrame(NSRect(x: x, y: y, width: displayWidth, height: displayHeight), display: true)
        videoView.needsLayout = true
    }
}
