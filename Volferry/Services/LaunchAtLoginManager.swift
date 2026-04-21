import Foundation
import ServiceManagement

enum LaunchAtLoginManager {
    private static let fallbackKey = VolFerryUserDefaults.Key.launchAtLoginEnabled
    
    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: fallbackKey)
    }
    
    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
        UserDefaults.standard.set(enabled, forKey: fallbackKey)
    }
}

