import AppKit
import ServiceManagement

/// Starts the app at login through a bundled launch agent (Contents/Library/LaunchAgents), whose
/// KeepAlive.SuccessfulExit=false makes launchd relaunch it after a crash but not after Quit.
enum LoginItem {
    static let label = "com.elabidi.glassmonitor.agent"
    private static let agent = SMAppService.agent(plistName: "\(label).plist")

    static var isEnabled: Bool { agent.status == .enabled }

    static func setEnabled(_ on: Bool) {
        try? on ? agent.register() : agent.unregister()
    }

    /// Earlier builds registered the app itself as a login item; replace that with the agent.
    static func migrateFromMainApp() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        setEnabled(true)
    }

    private static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Keeps a single instance. The agent-launched copy wins, so crash protection stays active;
    /// a copy opened from Finder while another runs just exits.
    /// Returns false if this process should exit.
    static func claimSingleInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return true }
        guard launchedByAgent else { return false }
        others.forEach { $0.terminate() }
        return true
    }
}
