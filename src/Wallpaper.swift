import AppKit
import AVFoundation
import QuartzCore

final class WallpaperController {
    static let shared = WallpaperController()

    private struct Panel {
        let window: NSWindow
        let playerLayer: AVPlayerLayer
    }

    private var panels: [Panel] = []
    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []
    private var loadToken = 0
    private var occlusionObserver: NSObjectProtocol?

    private(set) var currentSource: URL?
    private(set) var isPlaying = true
    private(set) var isMuted = true
    private var rate: Float = 1.0
    var currentRate: Float { rate }
    var statusBar: StatusBarController?

    private let recentsKey = "recentWallpapers"
    private let recentsLimit = 20

    private lazy var cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mac-livewallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func load(path: String) {
        let source = URL(fileURLWithPath: path)

        // no reloading!
        if source == currentSource {
            rewind()
            if !isPlaying { resume() }
            return
        }

        loadToken += 1
        let token = loadToken

        currentSource = source
        isPlaying = true
        pushRecent(source)

        setDesktopToFirstFrame(of: source)
        buildPanelsIfNeeded()

        transcodeToMOV(source: source) { [weak self] playable in
            guard let self, token == self.loadToken else { return }
            self.play(url: playable)
        }
    }

    func pause() {
        isPlaying = false
        applyPlayback()
    }

    func resume() {
        isPlaying = true
        applyPlayback()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func rewind() { players.forEach { $0.seek(to: .zero) } }

    func setRate(_ r: Float) {
        rate = r
        applyPlayback()
    }

    // play when visible, pause when not, like if they are watching a vid that takes the entire screen
    private func applyPlayback() {
        for panel in panels {
            guard let player = panel.playerLayer.player else { continue }
            if isPlaying && panel.window.occlusionState.contains(.visible) {
                player.rate = rate
            } else {
                player.pause()
            }
        }
    }

    // detect when the window is occluded and pause playback if so, resume if not
    private func observeOcclusion() {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyPlayback()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        players.forEach { $0.isMuted = isMuted }
    }

    func frameURL(for source: URL) -> URL {
        cacheDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-frame.png")
    }

    var currentFrameURL: URL? {
        guard let source = currentSource else { return nil }
        let url = frameURL(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var recents: [URL] {
        (UserDefaults.standard.array(forKey: recentsKey) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }

    private func pushRecent(_ source: URL) {
        var paths = UserDefaults.standard.array(forKey: recentsKey) as? [String] ?? []
        paths.removeAll { $0 == source.path }
        paths.insert(source.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(recentsLimit)), forKey: recentsKey)
    }

    func stop() {
        players.forEach { $0.pause() }
        players.removeAll()
        loopers.removeAll()
        panels.forEach { $0.window.orderOut(nil) }
        panels.removeAll()
    }

    private func play(url: URL) {
        players.forEach { $0.pause() }
        players.removeAll()
        loopers.removeAll()

        for panel in panels {
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = isMuted
            queuePlayer.actionAtItemEnd = .none
            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

            panel.playerLayer.player = queuePlayer
            players.append(queuePlayer)
            loopers.append(looper)
        }
        applyPlayback()
    }

    private func buildPanelsIfNeeded() {
        guard panels.isEmpty else { return }

        for screen in NSScreen.screens {
            let frame = screen.frame

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            // sit behind desktop icons, but above the bg
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            let host = CALayer()
            host.frame = view.bounds
            view.layer = host

            let playerLayer = AVPlayerLayer()
            playerLayer.frame = view.bounds
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.addSublayer(playerLayer)

            window.contentView = view
            window.orderFrontRegardless()

            panels.append(Panel(window: window, playerLayer: playerLayer))
        }
        observeOcclusion()
    }

    // mov is much better for support, performance, and literally fucking everything for mac
    private func transcodeToMOV(source: URL, completion: @escaping (URL) -> Void) {
        if source.pathExtension.lowercased() == "mov" {
            completion(source)
            return
        }

        let cached = cacheDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mov")
        if isCacheValid(cached, source: source) {
            completion(cached)
            return
        }

        guard let export = AVAssetExportSession(
            asset: AVURLAsset(url: source),
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            completion(source)
            return
        }

        try? FileManager.default.removeItem(at: cached)
        Task {
            // fall back to the source so a failed transcode still plays
            // even if the file is like lowkey corrupted, still try
            let result: URL
            do {
                try await export.export(to: cached, as: .mov)
                result = cached
            } catch {
                result = source
            }
            await MainActor.run { completion(result) }
        }
    }

    // check to see if we actually need to transcode or use a cached file
    private func isCacheValid(_ cached: URL, source: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cached.path),
              let cAttr = try? fm.attributesOfItem(atPath: cached.path),
              let sAttr = try? fm.attributesOfItem(atPath: source.path),
              let cDate = cAttr[.modificationDate] as? Date,
              let sDate = sAttr[.modificationDate] as? Date else { return false }
        return cDate >= sDate
    }

    // for new macos colors & such, also if the user closes the app, itll be stationary
    private func setDesktopToFirstFrame(of source: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        let frameURL = cacheDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-frame.png")

        Task {
            guard let cg = try? await generator.image(at: .zero).image,
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: frameURL)
            await MainActor.run {
                for screen in NSScreen.screens {
                    try? NSWorkspace.shared.setDesktopImageURL(frameURL, for: screen, options: [:])
                }
            }
        }
    }
}