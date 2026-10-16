import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Turns on launch at login the first time Headroom runs; later choices are left alone.
    static func registerOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do { try SMAppService.mainApp.register() } catch { Log.write("Login item registration failed: \(error)") }
        UserDefaults.standard.set(true, forKey: key)
    }
}
