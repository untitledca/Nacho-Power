import AppKit
import AVFoundation
import QuartzCore

/// The cat never takes keyboard focus or intercepts clicks, including inside its image.
enum OverlayCorner: String, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var videoSide: OverlayVideoSide {
        self == .bottomLeft || self == .topLeft ? .left : .right
    }

    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}

enum OverlayVideoSide: String, CaseIterable {
    case left, right

    var intro: String { self == .left ? "intro_left" : "intro" }
    var loop: String { self == .left ? "looping_left" : "loop" }
    var clips: [String] { [intro, loop] }
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
    enum PlaybackState: String { case hidden, intro, loop, dismissing }

    var onPlaybackError: ((String) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onDismissalFinished: (() -> Void)?
    private(set) var playbackState: PlaybackState = .hidden
    var isVisible: Bool { panel.isVisible }
    var isPreviewing: Bool { previewLoopTarget != nil }

    private let panel: CatOverlayPanel
    private let videoView: CatVideoView
    private let player = AVQueuePlayer()
    private let assets: [String: AVURLAsset]
    private var looper: AVPlayerLooper?
    private var introItem: AVPlayerItem?
    private var statusObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var previewLoopTarget: Int?
    private var previewTimeObserver: Any?
    private var generation = 0
    private var sideSwitchTask: Task<Void, Never>?
    private var activeSide: OverlayVideoSide?
    private var width: CGFloat = 320
    private var corner: OverlayCorner = .bottomRight
    private var screenIndex = 0
    private var fullScreen = true
    private var aspectRatios: [OverlayVideoSide: CGFloat] = [:]

    init(assetDirectory: URL) {
        assets = Dictionary(uniqueKeysWithValues: OverlayVideoSide.allCases.flatMap(\.clips).map {
            ($0, AVURLAsset(url: assetDirectory.appendingPathComponent("\($0).mov")))
        })
        videoView = CatVideoView(frame: .zero)
        panel = CatOverlayPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "Nacho Power Overlay"
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
        for side in OverlayVideoSide.allCases {
            if let asset = assets[side.loop] {
                Task { [weak self] in
                    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                          let size = try? await track.load(.naturalSize), size.height > 0 else { return }
                    self?.aspectRatios[side] = size.width / size.height
                    self?.positionPanel()
                }
            }
        }
    }

    func updateAppearance(width: CGFloat, corner: OverlayCorner, screenIndex: Int = 0, fullScreen: Bool = true) {
        let previousSide = self.corner.videoSide
        self.width = min(1000, max(160, width))
        self.corner = corner
        self.screenIndex = screenIndex
        self.fullScreen = fullScreen
        positionPanel()
        if previousSide != corner.videoSide, playbackState == .intro || playbackState == .loop {
            switchVideoSide()
        }
    }

    /// Idempotent while a real reminder is already playing.
    func startReminder() {
        guard playbackState == .hidden || playbackState == .dismissing || isPreviewing else { return }
        start(previewLoops: nil)
    }

    /// Plays intro, two complete loops, then pops away without changing reminder settings.
    func preview() { start(previewLoops: 2) }

    /// AC reconnects: stop either video immediately, then pop the frozen image away.
    func finishReminder() {
        guard playbackState != .hidden, playbackState != .dismissing else { return }
        sideSwitchTask?.cancel()
        sideSwitchTask = nil
        stopPreviewObserver()
        playbackState = .dismissing
        player.pause()
        looper?.disableLooping()
        looper = nil
        let expectedGeneration = generation
        let duration = 0.18
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.06, 0.01]
        scale.keyTimes = [0.0, 0.24, 1.0]
        scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.playerLayer.transform = CATransform3DMakeScale(0.01, 0.01, 1)
        videoView.playerLayer.opacity = 0
        videoView.playerLayer.add(group, forKey: "dismissalPop")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == expectedGeneration, self.playbackState == .dismissing else { return }
            self.hide()
            self.onDismissalFinished?()
        }
    }

    func hide() {
        clearPlayback()
        playbackState = .hidden
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?(false) }
    }

    /// Rebuilds the queue without changing window visibility or preview ownership.
    private func clearPlayback() {
        generation += 1
        sideSwitchTask?.cancel()
        sideSwitchTask = nil
        stopPreviewObserver()
        player.pause()
        videoView.playerLayer.removeAnimation(forKey: "dismissalPop")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.playerLayer.transform = CATransform3DIdentity
        videoView.playerLayer.opacity = 1
        CATransaction.commit()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        statusObservations.removeAll()
        introItem = nil
        previewLoopTarget = nil
        activeSide = nil
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
         "selectedSide": corner.videoSide.rawValue,
         "activeSide": activeSide?.rawValue ?? "none",
         "currentVideo": (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "none",
         "playbackTime": player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
         "playbackFraction": playbackFraction,
         "playbackGeneration": generation,
         "previewLoopsRemaining": previewLoopTarget.map { max(0, $0 - (looper?.loopCount ?? 0)) } ?? -1,
         "mirrored": videoView.playerLayer.transform.m11 < 0,
         "fullScreen": fullScreen,
         "screenIndex": screenIndex,
         "videoReady": videoView.playerLayer.isReadyForDisplay,
         "playerStatus": player.status.rawValue,
         "windowFrame": NSStringFromRect(panel.frame),
         "muted": player.isMuted,
         "playerRate": player.rate,
         "hasPopAnimation": videoView.playerLayer.animation(forKey: "dismissalPop") != nil,
         "loopCount": looper?.loopCount ?? 0]
    }

    private func start(previewLoops: Int?) {
        hide()
        guard configurePlayback(side: corner.videoSide, phase: .intro, previewLoops: previewLoops) else { return }
        positionPanel()
        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
    }

    private var playbackFraction: Double {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return 0 }
        let elapsed = player.currentTime().seconds
        return elapsed.isFinite ? min(1, max(0, elapsed / duration)) : 0
    }

    /// Swapping sides retains the phase and progress. A loop never replays the intro,
    /// and moving between top/bottom on the same side does not touch the queue.
    private func switchVideoSide() {
        sideSwitchTask?.cancel()
        let side = corner.videoSide
        player.pause()
        sideSwitchTask = Task { [weak self] in
            guard let self else { return }
            let introDuration = (try? await assets[side.intro]?.load(.duration))?.seconds ?? 0
            let loopDuration = (try? await assets[side.loop]?.load(.duration))?.seconds ?? 0
            guard !Task.isCancelled, corner.videoSide == side,
                  playbackState == .intro || playbackState == .loop else { return }
            // Read the phase after loading: a queued end-of-intro callback may have
            // advanced the player just before it was paused for this replacement.
            let phase = playbackState
            let duration = phase == .intro ? introDuration : loopDuration
            let time = duration.isFinite && duration > 0 ? min(0.999999, playbackFraction) * duration : 0
            let remainingLoops = previewLoopTarget.map { max(0, $0 - (self.looper?.loopCount ?? 0)) }
            if remainingLoops == 0 {
                finishReminder()
                return
            }
            sideSwitchTask = nil
            clearPlayback()
            guard configurePlayback(side: side, phase: phase, previewLoops: remainingLoops, seekTo: time) else { return }
            positionPanel()
        }
    }

    @discardableResult
    private func configurePlayback(side: OverlayVideoSide, phase: PlaybackState,
                                   previewLoops: Int?, seekTo time: Double = 0) -> Bool {
        guard side.clips.allSatisfy({ name in
            assets[name].map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
        }) else {
            failed("Cat videos are missing. Expected \(side.intro).mov and \(side.loop).mov in the app's Resources folder.")
            return false
        }
        activeSide = side
        previewLoopTarget = previewLoops
        playbackState = phase
        if phase == .intro {
            let intro = makeItem(side.intro)
            introItem = intro
            player.insert(intro, after: nil)
        }
        let loop = makeItem(side.loop)
        looper = AVPlayerLooper(player: player, templateItem: loop,
                                timeRange: .invalid,
                                existingItemsOrdering: .loopingItemsFollowExistingItems)
        for item in looper?.loopingPlayerItems ?? [] { observeStatus(item) }
        if let target = previewLoopTarget {
            // Check completed loops outside the end notification, while AVQueuePlayer
            // finishes advancing its queue. The pop then interrupts playback immediately.
            previewTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.playbackState == .loop,
                          let count = self.looper?.loopCount, count >= target else { return }
                    self.finishReminder()
                }
            }
        }
        if time > 0 {
            let expectedGeneration = generation
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == expectedGeneration,
                          self.playbackState == .intro || self.playbackState == .loop,
                          self.corner.videoSide == self.activeSide else { return }
                    self.player.play()
                }
            }
        } else {
            player.play()
        }
        return true
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
        item === introItem || player.items().contains(where: { $0 === item }) ||
        (looper?.loopingPlayerItems.contains(where: { $0 === item }) ?? false)
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item else { return }
        if item === introItem, playbackState == .intro {
            playbackState = .loop
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
        let aspectRatio = aspectRatios[activeSide ?? corner.videoSide] ?? (16.0 / 9.0)
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
