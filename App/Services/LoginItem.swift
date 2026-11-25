import ServiceManagement

/// "Open at Login": starts the app in the menu bar after login. The desktop widgets update only after Start, and not on standby.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but needs to be allowed in "System Settings → General → Login Items".
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turn on or off. Throws on failure (e.g. blocked in System Settings); the UI shows a notice.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
