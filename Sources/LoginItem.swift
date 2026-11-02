import AppKit
import ServiceManagement

/// Starts the app at login through a per-user launch agent (~/Library/LaunchAgents), whose
/// KeepAlive.SuccessfulExit=false makes launchd relaunch it after a crash but not after Quit.
///
/// A plain agent with an absolute path is used instead of SMAppService.agent: the bundle is rebuilt in
/// place by build.sh, and SMAppService then loses track of it (launchd fails every spawn with EX_CONFIG).
enum LoginItem {
    static let label = "com.elabidi.glassmonitor.login"
    private static let legacyAgentPlist = "com.elabidi.glassmonitor.agent.plist"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
        on ? enable() : disable()
    }

    private static func enable() {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (plist as NSDictionary).write(to: plistURL, atomically: true) else { return }
        if !isLoaded { _ = Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path]) }
    }

    /// Stops it starting at the next login. A copy launched by the agent keeps its crash protection until
    /// it quits (booting the job out would kill this very process).
    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
        if isLoaded && !launchedByAgent { _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"]) }
    }

    private static var isLoaded: Bool {
        Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    /// Earlier builds used SMAppService (the app itself, then a bundled agent); replace them with this agent.
    static func migrate() {
        let legacy = [SMAppService.mainApp, SMAppService.agent(plistName: legacyAgentPlist)]
        // Once the bundle is rebuilt without the bundled agent plist, SMAppService reports that agent as not found,
        // but launchd still has the job loaded; count that as enabled too, and stop it so it can't relaunch the app.
        let legacyJob = "\(domain)/\(legacyAgentPlist.replacingOccurrences(of: ".plist", with: ""))"
        let legacyLoaded = Shell.run("/bin/launchctl", ["print", legacyJob]).status == 0
        let wasEnabled = legacyLoaded || legacy.contains { $0.status == .enabled || $0.status == .requiresApproval }
        legacy.filter { $0.status != .notRegistered }.forEach { try? $0.unregister() }
        let launchedByLegacy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == legacyJob.components(separatedBy: "/").last
        if legacyLoaded && !launchedByLegacy { _ = Shell.run("/bin/launchctl", ["bootout", legacyJob]) }
        if wasEnabled && !isEnabled { enable() }
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
