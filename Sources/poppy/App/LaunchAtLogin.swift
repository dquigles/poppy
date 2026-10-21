import Foundation
import ServiceManagement

/// Launch at login (DESIGN §4): the system's login item for Poppy.app, not stored in
/// config.json. Read each time the settings page shows, since the user can change it in
/// System Settings → General → Login Items.
enum LaunchAtLogin {
    enum State: Equatable {
        case on, off, requiresApproval
        /// Poppy Dev, or no app bundle (`swift run`): never registered from here.
        case unavailable(String)

        var isOn: Bool { self == .on || self == .requiresApproval }
        var canChange: Bool { if case .unavailable = self { false } else { true } }

        var note: String? {
            switch self {
            case .on, .off: nil
            case .requiresApproval: "Allow \(AppVariant.name) in System Settings → Login Items."
            case .unavailable(let reason): reason
            }
        }
    }

    static var state: State {
        if AppVariant.isDev { return .unavailable("Not available in Poppy Dev.") }
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable("Needs the Poppy app.") }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    static func set(_ on: Bool) {
        guard state.canChange else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appLog("launch at login: \(on ? "on" : "off") (\(SMAppService.mainApp.status.rawValue))")
        } catch {
            appLog("launch at login: could not turn it \(on ? "on" : "off"): \(error)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
