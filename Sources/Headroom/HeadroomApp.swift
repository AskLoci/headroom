import AppKit
import HeadroomCore

@main
@MainActor
enum HeadroomMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.rotateIfLarge()
        LoginItem.registerOnFirstLaunch()
        let model = AppModel(paths: .current)
        self.model = model
        statusItem = StatusItemController(model: model)
        model.start()
    }

    /// Opening Headroom again from Spotlight or Finder shows it in a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showWindow()
        return false
    }
}
