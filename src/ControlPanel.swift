import AppKit
import SwiftUI
import Darwin
import ServiceManagement
import UniformTypeIdentifiers

// stats
enum ProcStats {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    static func cpuSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let sys = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + sys
    }

    static func cacheBytes() -> Int64 {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mac-livewallpaper", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

struct RecentItem: Identifiable {
    let url: URL
    let thumbnail: NSImage?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

final class PanelModel: ObservableObject {
    @Published var frame: NSImage?
    @Published var currentName = "No wallpaper"
    @Published var isPlaying = true
    @Published var isMuted = true
    @Published var rate: Float = 1.0
    @Published var recents: [RecentItem] = []
    @Published var memText = "—"
    @Published var cpuText = "—"
    @Published var cacheText = "—"
    @Published var launchAtLogin = false
    @Published var transcodeProgress: Double?
    @Published var errorMessage: String?

    let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5]
    // need an app bundle for this
    let canManageLogin = Bundle.main.bundleIdentifier != nil

    private var timer: Timer?
    private var lastCPU = ProcStats.cpuSeconds()
    private var lastSample = Date()

    func start() {
        let c = WallpaperController.shared
        c.progressHandler = { [weak self] p in
            DispatchQueue.main.async { self?.transcodeProgress = p }
        }
        c.errorHandler = { [weak self] m in
            DispatchQueue.main.async { self?.errorMessage = m }
        }
        tick()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let c = WallpaperController.shared
        let name = c.currentSource?.lastPathComponent ?? "No wallpaper"
        if name != currentName || frame == nil {
            currentName = name
            frame = c.currentFrameURL.flatMap { NSImage(contentsOf: $0) }
            recents = c.recents.map { RecentItem(url: $0, thumbnail: NSImage(contentsOf: c.frameURL(for: $0))) }
        }
        isPlaying = c.isPlaying
        isMuted = c.isMuted
        rate = c.currentRate
        if canManageLogin { launchAtLogin = SMAppService.mainApp.status == .enabled }
        updateStats()
    }

    private func updateStats() {
        let mib = 1024.0 * 1024.0
        memText = String(format: "%.0f MiB", Double(ProcStats.residentBytes()) / mib)
        cacheText = String(format: "%.0f MiB", Double(ProcStats.cacheBytes()) / mib)

        let now = Date()
        let cpuNow = ProcStats.cpuSeconds()
        let dt = now.timeIntervalSince(lastSample)
        if dt > 0 {
            cpuText = String(format: "%.1f%%", max(0, (cpuNow - lastCPU) / dt * 100))
        }
        lastCPU = cpuNow
        lastSample = now
    }

    func clearCache() {
        WallpaperController.shared.clearCache()
        tick()
    }

    func togglePlay() {
        WallpaperController.shared.togglePlayPause()
        isPlaying = WallpaperController.shared.isPlaying
    }

    func rewind() { WallpaperController.shared.rewind() }

    func setRate(_ r: Float) {
        WallpaperController.shared.setRate(r)
        rate = r
    }

    func toggleMute() {
        WallpaperController.shared.toggleMute()
        isMuted = WallpaperController.shared.isMuted
    }

    func load(_ url: URL) {
        errorMessage = nil
        WallpaperController.shared.load(path: url.path)
        tick()
    }

    func openFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        // use UTType(filenameExtension:) to avoid hardcoding UTI strings
        types += ["webm", "mkv", "avi"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func toggleLaunchAtLogin() {
        guard canManageLogin else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("launch at login toggle failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        WallpaperController.shared.stop()
        NSApp.terminate(nil)
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: PanelModel
    @State private var showRecents = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
            if showRecents {
                Divider()
                recentsSidebar
            }
        }
        .onAppear { model.start() }
    }

    private var mainColumn: some View {
        VStack(spacing: 12) {
            header
            errorBanner
            controls
            openButton
            Divider()
            speedSection
            Divider()
            recentsButton
            Divider()
            statsSection
            Divider()
            loginToggle
            Divider()
            clearCacheButton
            quitButton
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        ZStack {
            if let frame = model.frame {
                Image(nsImage: frame).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
            if let progress = model.transcodeProgress {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        Text("Processing… \(Int(progress * 100))%")
                            .font(.caption).bold().foregroundStyle(.white)
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            Text(model.currentName)
                .font(.caption).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(8)
        }
    }

    private var errorBanner: some View {
        Group {
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.errorMessage = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            Button { model.rewind() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title)
            }
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    private var openButton: some View {
        Button { model.openFile() } label: {
            Label("Open Video…", systemImage: "folder").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback Speed").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(model.speeds, id: \.self) { speed in
                    Text(String(format: "%gx", speed)).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var recentsButton: some View {
        Button { showRecents.toggle() } label: {
            HStack {
                Text("Recents").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.recents.count)").font(.caption2).foregroundStyle(.tertiary)
                Image(systemName: showRecents ? "chevron.left" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recents").font(.headline)
            if model.recents.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.recents) { item in
                            Button { model.load(item.url) } label: {
                                HStack(spacing: 8) {
                                    thumbnail(item.thumbnail)
                                    Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 230, height: 430)
    }

    private var statsSection: some View {
        VStack(spacing: 4) {
            statRow("Cache", model.cacheText)
            statRow("Memory", model.memText)
            statRow("CPU", model.cpuText)
        }
    }

    private var loginToggle: some View {
        Toggle("Start at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { _ in model.toggleLaunchAtLogin() }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        .disabled(!model.canManageLogin)
        .help(model.canManageLogin ? "" : "unavaliable due to loose binary")
    }

    private var clearCacheButton: some View {
        Button { model.clearCache() } label: {
            Label("Clear Cache", systemImage: "trash").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var quitButton: some View {
        Button(role: .destructive) { model.quit() } label: {
            Label("Quit", systemImage: "power").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private func thumbnail(_ image: NSImage?) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(.quaternary) }
        }
        .frame(width: 36, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

final class StatusBarController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model = PanelModel()

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                                     accessibilityDescription: "Live Wallpaper")
        item.button?.action = #selector(toggle)
        item.button?.target = self

        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: ControlPanelView(model: model))
        
        // use proper sizing
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
