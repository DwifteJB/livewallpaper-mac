import AppKit
import AVFoundation
import QuartzCore

// mutable seconds holder so the ffmpeg log closure stays sendable
private final class DurationBox {
    var seconds: Double = 0
}

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

    // if nil, no progress
    var progressHandler: ((Double?) -> Void)?
    var errorHandler: ((String) -> Void)?

    // formats needing for ffmpeg
    private let ffmpegFormats: Set<String> = ["webm", "mkv", "avi", "flv", "wmv", "ogv"]

    private func reportProgress(_ p: Double?) { progressHandler?(p) }
    private func reportError(_ m: String) { errorHandler?(m) }

    private static func ffmpegPath() -> String? {
        let fm = FileManager.default
        // bundled ffmpeg ships in the .app's Resources, or next to the loose binary
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg").path,
        ].compactMap { $0 }
        // fall back to a system install if the bundle somehow shipped without it
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private let recentsKey = "recentWallpapers"
    private let recentsLimit = 20

    private lazy var cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mac-livewallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

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
        buildPanelsIfNeeded()

        // for formats requiring fffffmpeg
        let needsFFmpeg = ffmpegFormats.contains(source.pathExtension.lowercased())
        if !needsFFmpeg { setDesktopToFirstFrame(of: source) }

        reportProgress(0)
        transcodeToMOV(source: source) { [weak self] playable in
            guard let self, token == self.loadToken else { return }
            self.reportProgress(nil)
            self.play(url: playable)
            if needsFFmpeg { self.setDesktopToFirstFrame(of: playable) }
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
        let ext = source.pathExtension.lowercased()
        if ext == "mov" {
            completion(source)
            return
        }

        let cached = cacheDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mov")
        if isCacheValid(cached, source: source) {
            completion(cached)
            return
        }
        try? FileManager.default.removeItem(at: cached)

        if ffmpegFormats.contains(ext) {
            transcodeWithFFmpeg(source: source, to: cached, completion: completion)
        } else {
            transcodeWithAVFoundation(source: source, to: cached, completion: completion)
        }
    }

    private func transcodeWithAVFoundation(source: URL, to cached: URL, completion: @escaping (URL) -> Void) {
        guard let export = AVAssetExportSession(
            asset: AVURLAsset(url: source),
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            completion(source)
            return
        }

        Task {
            // fall back to the source so a failed transcode still plays
            // even if the file is like lowkey corrupted, still try
            let result: URL
            do {
                // states() only observes, export(to:as:) drives it, so run them together
                async let exportRun: Void = export.export(to: cached, as: .mov)
                for await state in export.states(updateInterval: 0.15) {
                    if case .exporting(let progress) = state {
                        self.reportProgress(progress.fractionCompleted)
                    }
                }
                try await exportRun
                result = cached
            } catch {
                result = source
            }
            await MainActor.run { completion(result) }
        }
    }

    private func transcodeWithFFmpeg(source: URL, to cached: URL, completion: @escaping (URL) -> Void) {
        guard let ffmpeg = Self.ffmpegPath() else {
            reportError("ffmpeg is missing — \(source.pathExtension.lowercased()) files need the bundled ffmpeg. rebuild with `zsh ./build-app.sh`, or `brew install ffmpeg`.")
            completion(source)
            return
        }

        let report = progressHandler
        Task.detached {
            // gpu encode first, fall back to software h.264 if this ffmpeg lacks videotoolbox
            let videotoolbox = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-b:v", "10M"]
            let software = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "veryfast"]

            let ok = Self.runFFmpeg(ffmpeg, source: source, to: cached, videoArgs: videotoolbox, report: report)
                || {
                    report?(0)
                    return Self.runFFmpeg(ffmpeg, source: source, to: cached, videoArgs: software, report: report)
                }()
            await MainActor.run { completion(ok ? cached : source) }
        }
    }

    // runs ffmpeg to completion (blocking, call off-main), wiring stderr to the progress report. true on success
    private static func runFFmpeg(_ ffmpeg: String, source: URL, to cached: URL, videoArgs: [String], report: ((Double?) -> Void)?) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-i", source.path] + videoArgs + ["-c:a", "aac", cached.path]

        // ffmpeg logs to stderr, parse Duration: once then time= per line for a fraction.
        // the handle's queue serializes these calls, the box just keeps duration sendable
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()
        let duration = DurationBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            if duration.seconds == 0, let d = parseFFmpegTime(chunk, key: "Duration:") {
                duration.seconds = d
            }
            if duration.seconds > 0, let t = parseFFmpegTime(chunk, key: "time=") {
                report?(min(1, t / duration.seconds))
            }
        }

        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: cached.path)
    }

    // pulls the first "<key> HH:MM:SS.ss" timestamp out of an ffmpeg log chunk, as seconds
    private static func parseFFmpegTime(_ text: String, key: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...].drop { $0 == " " }
        let stamp = tail.prefix { "0123456789:.".contains($0) }
        let parts = stamp.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
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