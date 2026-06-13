import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// if theres an arg we use that, otherwise last path / none
if CommandLine.arguments.count >= 2 {
    WallpaperController.shared.load(path: CommandLine.arguments[1])
} else if let last = WallpaperController.shared.recents.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
    WallpaperController.shared.load(path: last.path)
}

WallpaperController.shared.statusBar = StatusBarController()
app.run()
