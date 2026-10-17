import AppKit
import AVFoundation
import QuartzCore

/// The cat never takes keyboard focus. Video windows always stay click-through.
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

    var title: String { self == .left ? "From Left" : "From Right" }

    var intro: String { self == .left ? "intro_left" : "intro" }
    var loop: String { self == .left ? "looping_left" : "loop" }
    var clips: [String] { [intro, loop] }
}

/// One player per display: AVPlayer cannot render into several player layers at
/// once. The coordinator owns the single reminder/preview lifecycle and keeps
/// display changes from restarting a clip or dismissing only one of the cats.
@MainActor
final class CatOverlayController {
    enum PlaybackState: String { case hidden, intro, loop, dismissing }
    var onPlaybackError: ((String) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onDismissalFinished: (() -> Void)?
    var onSnoozeRequested: (() -> Void)?

    private let assetDirectory: URL
    private let displays: @MainActor () -> [OverlayDisplay]
    private var surfaces: [String: CatOverlaySurface] = [:]
    private var displayOrder: [String] = []
    private var screenObserver: NSObjectProtocol?
    private var width: CGFloat = 320
    private var corner: OverlayCorner = .bottomRight
    private var fullScreen = true
    private var clickToSnooze = false
    private var snoozeRequested = false
    private var fullScreenSide: OverlayVideoSide = .right
    private var displaySelection = OverlayDisplaySelection.main
    private var wantsPlayback = false
    private var previewRequested = false
    private var dismissing = false
    private var reconciling = false
    private var lastVisibility = false
    private var suspendedSnapshot: OverlayPlaybackSnapshot?

    var isVisible: Bool { surfaces.values.contains { $0.isVisible || $0.isStarting } }
    var isPreviewing: Bool { previewRequested && !dismissing }
    var playbackState: PlaybackState {
        if dismissing { return .dismissing }
        return leadingSurface?.playbackState ?? suspendedSnapshot?.phase ?? .hidden
    }
    private var selectedSide: OverlayVideoSide { fullScreen ? fullScreenSide : corner.videoSide }
    private var leadingSurface: CatOverlaySurface? {
        displayOrder.compactMap { surfaces[$0] }.first(where: { $0.playbackState != .hidden })
            ?? displayOrder.compactMap { surfaces[$0] }.first
    }

    init(assetDirectory: URL, displays: @escaping @MainActor () -> [OverlayDisplay] = { OverlayDisplay.availableDisplays }) {
        self.assetDirectory = assetDirectory
        self.displays = displays
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
        refreshDisplays()
    }

    /// screenIndex remains for older callers; saved settings now use stable IDs.
    func updateAppearance(width: CGFloat, corner: OverlayCorner, screenIndex: Int = 0,
                          fullScreen: Bool = true, fullScreenSide: OverlayVideoSide? = nil,
                          displaySelection: String = OverlayDisplaySelection.main,
                          clickToSnooze: Bool = false) {
        self.width = width
        self.corner = corner
        self.fullScreen = fullScreen
        self.clickToSnooze = clickToSnooze
        self.fullScreenSide = fullScreenSide ?? corner.videoSide
        let connected = displays()
        self.displaySelection = displaySelection == OverlayDisplaySelection.main && screenIndex > 0 && connected.indices.contains(screenIndex)
            ? connected[screenIndex].id : displaySelection
        refreshDisplays()
    }

    /// Reconcile monitor geometry and membership without replaying the intro.
    func refreshDisplays() {
        let targets = OverlayDisplaySelection.selectedDisplays(for: displaySelection, from: displays())
        let snapshot = leadingSurface?.snapshot ?? suspendedSnapshot
        reconciling = true
        defer {
            reconciling = false
            publishVisibility()
            finishDismissalIfReady()
        }
        let ids = Set(targets.map(\.id))
        // Keep the original players on retained displays, even if macOS changes
        // the enumeration order. Newly connected displays join the saved phase.
        for display in targets {
            if let existing = surfaces[display.id] {
                existing.updateAppearance(width: width, corner: corner, display: display,
                                          fullScreen: fullScreen, side: selectedSide)
            } else if !dismissing {
                let surface = makeSurface(display)
                surfaces[display.id] = surface
                surface.updateAppearance(width: width, corner: corner, display: display,
                                         fullScreen: fullScreen, side: selectedSide)
                if wantsPlayback {
                    if let snapshot { surface.resume(snapshot) }
                    else if previewRequested { surface.preview() }
                    else { surface.startReminder() }
                }
            }
        }
        for id in Array(surfaces.keys) where !ids.contains(id) {
            surfaces.removeValue(forKey: id)?.hide()
        }
        displayOrder = targets.map(\.id)
        suspendedSnapshot = targets.isEmpty && wantsPlayback ? snapshot : nil
    }

    func startReminder() {
        guard !wantsPlayback || dismissing || previewRequested else { return }
        start(preview: false)
    }

    func preview() { start(preview: true) }

    private func start(preview: Bool) {
        hide()
        wantsPlayback = true
        previewRequested = preview
        refreshDisplays()
        reconciling = true
        for surface in Array(surfaces.values) {
            guard wantsPlayback else { break }
            if preview { surface.preview() } else { surface.startReminder() }
        }
        reconciling = false
        publishVisibility()
    }

    func finishReminder() {
        guard wantsPlayback, !dismissing else { return }
        dismissing = true
        previewRequested = false
        updateClickInteraction()
        // All surfaces pause and start the same pop in this main-actor turn.
        for surface in Array(surfaces.values) { surface.finishReminder() }
        finishDismissalIfReady()
    }

    func hide() {
        wantsPlayback = false
        previewRequested = false
        dismissing = false
        snoozeRequested = false
        suspendedSnapshot = nil
        reconciling = true
        for surface in Array(surfaces.values) { surface.hide() }
        reconciling = false
        publishVisibility()
    }

    private func makeSurface(_ display: OverlayDisplay) -> CatOverlaySurface {
        let surface = CatOverlaySurface(assetDirectory: assetDirectory, display: display)
        surface.onPlaybackError = { [weak self] error in
            guard let self else { return }
            hide()
            onPlaybackError?(error)
        }
        surface.onVisibilityChanged = { [weak self] _ in
            guard let self, !reconciling else { return }
            publishVisibility()
        }
        surface.onSnoozeRequested = { [weak self] in self?.requestSnooze() }
        surface.onPreviewFinished = { [weak self] in self?.finishReminder() }
        surface.onDismissalFinished = { [weak self] in self?.finishDismissalIfReady() }
        return surface
    }

    private func finishDismissalIfReady() {
        guard dismissing, !reconciling, !isVisible else { return }
        wantsPlayback = false
        dismissing = false
        suspendedSnapshot = nil
        publishVisibility()
        onDismissalFinished?()
    }

    private func requestSnooze() {
        guard clickToSnooze, wantsPlayback, !previewRequested, !dismissing,
              !snoozeRequested, let onSnoozeRequested else { return }
        snoozeRequested = true
        // Disarm every display before invoking the owner, even if its callback
        // does not immediately start the dismissal animation.
        updateClickInteraction()
        onSnoozeRequested()
    }

    private func updateClickInteraction() {
        let enabled = clickToSnooze && wantsPlayback && !previewRequested && !dismissing && !snoozeRequested
        for surface in surfaces.values { surface.setClickToSnooze(enabled) }
    }

    private func publishVisibility() {
        updateClickInteraction()
        let visible = isVisible
        guard visible != lastVisibility else { return }
        lastVisibility = visible
        onVisibilityChanged?(visible)
    }

    var diagnostics: [String: Any] {
        var result = leadingSurface?.diagnostics ?? [:]
        result["visible"] = isVisible
        result["playbackState"] = playbackState.rawValue
        result["selectedSide"] = selectedSide.rawValue
        result["displaySelection"] = displaySelection
        result["displayCount"] = surfaces.count
        result["clickToSnooze"] = clickToSnooze
        result["snoozeRequested"] = snoozeRequested
        result["displays"] = displayOrder.compactMap { surfaces[$0]?.diagnostics }
        return result
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

private struct OverlayPlaybackSnapshot {
    let phase: CatOverlayController.PlaybackState
    let fraction: Double
    let previewLoops: Int?
}

private final class CatOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OverlayCanvasLayout {
    static func frame(in bounds: CGRect, aspect: CGFloat, side: OverlayVideoSide,
                      fullScreen: Bool) -> CGRect {
        guard fullScreen else { return bounds }
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        // Keep the entire canvas on portrait displays instead of cropping a
        // landscape clip to fill their height. Extra space stays transparent.
        let width = min(max(0, bounds.width), max(0, bounds.height) * safeAspect)
        let height = width / safeAspect
        return CGRect(x: side == .left ? bounds.minX : bounds.maxX - width,
                      y: bounds.minY, width: width, height: height)
    }
}

/// The capture panel covers only this rectangle, never the video canvas. Pixels
/// are sampled off the main thread; expansion by one sample keeps thin fur/tails
/// inside the target. Fully opaque buffers are rejected because they have lost
/// the alpha channel and would otherwise turn a screen into a click blocker.
enum OverlayCatBounds {
    static func alphaBounds(bgra: UnsafeRawPointer, width: Int, height: Int,
                            bytesPerRow: Int, sampleStep: Int = 4) -> CGRect? {
        guard width > 0, height > 0, width <= Int.max / 4,
              bytesPerRow >= width * 4, height <= Int.max / bytesPerRow else { return nil }
        let step = max(1, sampleStep)
        let bytes = bgra.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var foundTransparency = false
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                if bytes[y * bytesPerRow + x * 4 + 3] > 32 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                } else { foundTransparency = true }
            }
        }
        guard maxX >= minX, maxY >= minY, foundTransparency else { return nil }
        let left = max(0, minX - step), right = min(width, maxX + step + 1)
        let top = max(0, minY - step), bottom = min(height, maxY + step + 1)
        // Pixel buffers start at the top; AppKit's unflipped views start below.
        return CGRect(x: Double(left) / Double(width), y: 1 - Double(bottom) / Double(height),
                      width: Double(right - left) / Double(width), height: Double(bottom - top) / Double(height))
    }

    static func screenRect(normalizedBounds: CGRect, videoRect: CGRect) -> CGRect? {
        guard [normalizedBounds.origin.x, normalizedBounds.origin.y, normalizedBounds.width, normalizedBounds.height,
               videoRect.origin.x, videoRect.origin.y, videoRect.width, videoRect.height].allSatisfy(\.isFinite),
              !normalizedBounds.isNull, !normalizedBounds.isInfinite,
              !videoRect.isNull, !videoRect.isInfinite,
              normalizedBounds.width > 0, normalizedBounds.height > 0,
              videoRect.width > 0, videoRect.height > 0 else { return nil }
        let unit = normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !unit.isEmpty else { return nil }
        let target = CGRect(x: videoRect.minX + unit.minX * videoRect.width,
                            y: videoRect.minY + unit.minY * videoRect.height,
                            width: unit.width * videoRect.width, height: unit.height * videoRect.height)
        let bounded = target.insetBy(dx: -2, dy: -2).intersection(videoRect)
        // A malformed alpha frame must never make the entire video interactive.
        guard bounded != videoRect else { return nil }
        return bounded
    }
}

/// Receives the first click without activating the app or making a key window.
/// The transparent corners inside this small rectangle are deliberately consumed
/// too, so a captured click cannot activate a button in an underlying app.
private final class CatSnoozeView: NSView {
    var onClick: (() -> Void)?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

private final class CatVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    var fitEntireCanvas = false
    var videoAspect: CGFloat = 16.0 / 9.0
    var videoSide: OverlayVideoSide = .right

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
        playerLayer.frame = OverlayCanvasLayout.frame(in: bounds, aspect: videoAspect,
                                                       side: videoSide, fullScreen: fitEntireCanvas)
        CATransaction.commit()
    }
}

/// Uses AVFoundation's native video layers and decoder, with no frame-copy timer.
/// Bundle assets should be HEVC with alpha, converted once from the user's ProRes masters.
@MainActor
private final class CatOverlaySurface {
    typealias PlaybackState = CatOverlayController.PlaybackState

    var onPlaybackError: ((String) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onDismissalFinished: (() -> Void)?
    var onPreviewFinished: (() -> Void)?
    var onSnoozeRequested: (() -> Void)?
    private(set) var playbackState: PlaybackState = .hidden
    var isVisible: Bool { panel.isVisible }
    var isStarting: Bool { pendingResume != nil }
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
    private var previewLoopTarget: Int?
    private var previewTimeObserver: Any?
    private var generation = 0
    private var sideSwitchTask: Task<Void, Never>?
    private var activeSide: OverlayVideoSide?
    private var width: CGFloat = 320
    private var corner: OverlayCorner = .bottomRight
    private var display: OverlayDisplay
    private var selectedSide: OverlayVideoSide = .right
    private var pendingResume: OverlayPlaybackSnapshot?
    private var fullScreen = true
    private var aspectRatios: [OverlayVideoSide: CGFloat] = [:]
    private var clickInteractionEnabled = false
    private var inputPanel: CatOverlayPanel?
    private var inputTimer: Timer?
    private var inputOutput: AVPlayerItemVideoOutput?
    private var inputItem: AVPlayerItem?
    private var inputGeneration = 0
    private var inputSamplePending = false
    private var latestCatBounds: CGRect?
    private var latestCatBoundsTime: CFTimeInterval = 0
    private let inputQueue = DispatchQueue(label: "com.atomfilmlab.ecoflowcat.cat-alpha", qos: .utility)

    init(assetDirectory: URL, display: OverlayDisplay) {
        self.display = display
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

    func updateAppearance(width: CGFloat, corner: OverlayCorner, display: OverlayDisplay,
                          fullScreen: Bool, side: OverlayVideoSide) {
        let previousSide = selectedSide
        self.width = min(1000, max(160, width))
        self.corner = corner
        self.display = display
        self.fullScreen = fullScreen
        selectedSide = side
        positionPanel()
        if previousSide != selectedSide {
            if let snapshot = pendingResume { resume(snapshot) }
            else if playbackState == .intro || playbackState == .loop { switchVideoSide() }
        }
    }

    var snapshot: OverlayPlaybackSnapshot? {
        if let pendingResume { return pendingResume }
        guard playbackState == .intro || playbackState == .loop else { return nil }
        return OverlayPlaybackSnapshot(phase: playbackState, fraction: playbackFraction,
            previewLoops: previewLoopTarget.map { max(0, $0 - (looper?.loopCount ?? 0)) })
    }

    /// A newly selected/connected display joins the existing phase and progress.
    func resume(_ snapshot: OverlayPlaybackSnapshot) {
        hide()
        pendingResume = snapshot
        let expectedGeneration = generation
        let side = selectedSide
        sideSwitchTask = Task { [weak self] in
            guard let self else { return }
            let clip = snapshot.phase == .intro ? side.intro : side.loop
            let duration = (try? await assets[clip]?.load(.duration))?.seconds ?? 0
            guard !Task.isCancelled, generation == expectedGeneration, selectedSide == side else { return }
            pendingResume = nil
            sideSwitchTask = nil
            let time = duration.isFinite && duration > 0 ? min(0.999999, snapshot.fraction) * duration : 0
            guard configurePlayback(side: side, phase: snapshot.phase,
                                    previewLoops: snapshot.previewLoops, seekTo: time) else { return }
            positionPanel()
            panel.orderFrontRegardless()
            onVisibilityChanged?(true)
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
        stopClickSampling()
        if pendingResume != nil { hide(); return }
        guard playbackState != .hidden, playbackState != .dismissing else { return }
        sideSwitchTask?.cancel()
        sideSwitchTask = nil
        pendingResume = nil
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
        stopClickSampling()
        generation += 1
        sideSwitchTask?.cancel()
        sideSwitchTask = nil
        pendingResume = nil
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
         "selectedSide": selectedSide.rawValue,
         "activeSide": activeSide?.rawValue ?? "none",
         "currentVideo": (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "none",
         "playbackTime": player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
         "playbackFraction": playbackFraction,
         "playbackGeneration": generation,
         "previewLoopsRemaining": previewLoopTarget.map { max(0, $0 - (looper?.loopCount ?? 0)) } ?? -1,
         "mirrored": videoView.playerLayer.transform.m11 < 0,
         "fullScreen": fullScreen,
         "displayID": display.id,
         "displayName": display.name,
         "videoReady": videoView.playerLayer.isReadyForDisplay,
         "playerStatus": player.status.rawValue,
         "windowFrame": NSStringFromRect(panel.frame),
         "videoFrame": NSStringFromRect(videoView.playerLayer.frame),
         "muted": player.isMuted,
         "playerRate": player.rate,
         "hasPopAnimation": videoView.playerLayer.animation(forKey: "dismissalPop") != nil,
         "loopCount": looper?.loopCount ?? 0,
         "clickToSnooze": clickInteractionEnabled,
         "snoozeTargetVisible": inputPanel?.isVisible ?? false,
         "snoozeTargetFrame": NSStringFromRect(inputPanel?.frame ?? .zero),
         "snoozeSampling": inputTimer != nil,
         "snoozeTargetCanBecomeKey": inputPanel?.canBecomeKey ?? false,
         "snoozeTargetCanBecomeMain": inputPanel?.canBecomeMain ?? false]
    }

    private func start(previewLoops: Int?) {
        hide()
        guard configurePlayback(side: selectedSide, phase: .intro, previewLoops: previewLoops) else { return }
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
        let side = selectedSide
        player.pause()
        sideSwitchTask = Task { [weak self] in
            guard let self else { return }
            let introDuration = (try? await assets[side.intro]?.load(.duration))?.seconds ?? 0
            let loopDuration = (try? await assets[side.loop]?.load(.duration))?.seconds ?? 0
            guard !Task.isCancelled, selectedSide == side,
                  playbackState == .intro || playbackState == .loop else { return }
            // Read the phase after loading: a queued end-of-intro callback may have
            // advanced the player just before it was paused for this replacement.
            let phase = playbackState
            let duration = phase == .intro ? introDuration : loopDuration
            let time = duration.isFinite && duration > 0 ? min(0.999999, playbackFraction) * duration : 0
            let remainingLoops = previewLoopTarget.map { max(0, $0 - (self.looper?.loopCount ?? 0)) }
            if remainingLoops == 0 {
                onPreviewFinished?()
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
                    self.onPreviewFinished?()
                }
            }
        }
        if time > 0 {
            let expectedGeneration = generation
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == expectedGeneration,
                          self.playbackState == .intro || self.playbackState == .loop,
                          self.selectedSide == self.activeSide else { return }
                    self.player.play()
                }
            }
        } else {
            player.play()
        }
        refreshClickSampling()
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

    deinit {
        inputTimer?.invalidate()
        sideSwitchTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    func setClickToSnooze(_ enabled: Bool) {
        clickInteractionEnabled = enabled
        refreshClickSampling()
    }

    private func refreshClickSampling() {
        guard clickInteractionEnabled, panel.isVisible, !isPreviewing,
              playbackState == .intro || playbackState == .loop else {
            stopClickSampling()
            return
        }
        guard inputTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCatBounds() }
        }
        inputTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sampleCatBounds()
    }

    private func stopClickSampling() {
        inputTimer?.invalidate()
        inputTimer = nil
        resetClickOutput()
    }

    private func resetClickOutput() {
        inputGeneration += 1
        if let inputOutput, let inputItem { inputItem.remove(inputOutput) }
        inputOutput = nil
        inputItem = nil
        inputSamplePending = false
        latestCatBounds = nil
        latestCatBoundsTime = 0
        inputPanel?.orderOut(nil)
    }

    private func sampleCatBounds() {
        guard inputTimer != nil, panel.isVisible,
              playbackState == .intro || playbackState == .loop,
              let item = player.currentItem else { return }
        if inputItem !== item {
            resetClickOutput()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.suppressesPlayerRendering = false
            item.add(output)
            inputItem = item
            inputOutput = output
        }
        // Never leave a stale rectangle over the desktop after a stalled decode.
        if CACurrentMediaTime() - latestCatBoundsTime > 0.6 { inputPanel?.orderOut(nil) }
        guard !inputSamplePending, let output = inputOutput else { return }
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return }
        let expectedGeneration = inputGeneration
        inputSamplePending = true
        inputQueue.async { [weak self] in
            var bounds: CGRect?
            var decoded = false
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
               CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    decoded = true
                    bounds = OverlayCatBounds.alphaBounds(bgra: base,
                        width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            let result = bounds
            let hasFrame = decoded
            DispatchQueue.main.async {
                guard let self, self.inputGeneration == expectedGeneration else { return }
                self.inputSamplePending = false
                guard self.inputTimer != nil, self.player.currentItem === item else { return }
                if hasFrame {
                    self.latestCatBounds = result
                    self.latestCatBoundsTime = CACurrentMediaTime()
                    self.positionInputPanel()
                }
            }
        }
    }

    private func positionInputPanel() {
        guard inputTimer != nil, panel.isVisible, let latestCatBounds,
              CACurrentMediaTime() - latestCatBoundsTime <= 0.6,
              videoView.playerLayer.isReadyForDisplay, let root = videoView.layer else {
            inputPanel?.orderOut(nil)
            return
        }
        videoView.layoutSubtreeIfNeeded()
        let layerRect = root.convert(videoView.playerLayer.videoRect, from: videoView.playerLayer)
        let windowRect = videoView.convert(layerRect, to: nil)
        let videoRect = panel.convertToScreen(windowRect)
        guard let target = OverlayCatBounds.screenRect(normalizedBounds: latestCatBounds, videoRect: videoRect),
              target.width > 0, target.height > 0 else {
            inputPanel?.orderOut(nil)
            return
        }
        let capture: CatOverlayPanel
        if let inputPanel { capture = inputPanel }
        else {
            capture = CatOverlayPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            capture.title = "Nacho Power — Click cat to snooze"
            capture.isOpaque = false
            capture.backgroundColor = .clear
            capture.hasShadow = false
            capture.ignoresMouseEvents = false
            capture.isMovable = false
            capture.isMovableByWindowBackground = false
            capture.hidesOnDeactivate = false
            capture.becomesKeyOnlyIfNeeded = true
            capture.isReleasedWhenClosed = false
            capture.level = panel.level
            capture.collectionBehavior = panel.collectionBehavior
            let view = CatSnoozeView(frame: CGRect(origin: .zero, size: target.size))
            view.onClick = { [weak self] in
                guard let self, self.clickInteractionEnabled, self.inputTimer != nil else { return }
                self.onSnoozeRequested?()
            }
            capture.contentView = view
            inputPanel = capture
        }
        capture.setFrame(target, display: false)
        capture.order(.above, relativeTo: panel.windowNumber)
    }

    private func positionPanel() {
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.fitEntireCanvas = fullScreen
        videoView.videoAspect = aspectRatios[activeSide ?? selectedSide] ?? (16.0 / 9.0)
        videoView.videoSide = activeSide ?? selectedSide
        if fullScreen {
            panel.setFrame(display.frame, display: true)
            videoView.needsLayout = true
            positionInputPanel()
            return
        }
        let available = display.visibleFrame
        let displayWidth = max(1, min(width, available.width - 32, (available.height - 32) * (aspectRatios[activeSide ?? selectedSide] ?? (16.0 / 9.0))))
        let aspectRatio = aspectRatios[activeSide ?? selectedSide] ?? (16.0 / 9.0)
        let displayHeight = displayWidth / aspectRatio
        let inset: CGFloat = 16
        let left = corner == .bottomLeft || corner == .topLeft
        let bottom = corner == .bottomLeft || corner == .bottomRight
        let x = left ? available.minX + inset : available.maxX - displayWidth - inset
        let y = bottom ? available.minY + inset : available.maxY - displayHeight - inset
        panel.setFrame(NSRect(x: x, y: y, width: displayWidth, height: displayHeight), display: true)
        videoView.needsLayout = true
        positionInputPanel()
    }
}
