import Foundation
import UserNotifications

struct MonitorAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    /// Set for runaway-process alerts, which offer Quit / Ignore.
    let pid: pid_t?
    let processName: String?
    /// Other alerts offer a button that opens this tab (memory → Memory, low disk → Clean).
    var opensTab: ListTab = .memory
}

/// Flags a process that stays above 80% CPU for 2 minutes. Each process is reported once per busy streak.
final class RunawayDetector {
    private static let busyThreshold = 80.0
    private static let calmThreshold = 50.0
    private static let duration: TimeInterval = 120

    private var busySince: [pid_t: Date] = [:]
    private var reported = Set<pid_t>()
    private var ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredRunaways") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignored), forKey: "ignoredRunaways") }
    }

    func ignore(_ name: String) { ignored.insert(name) }

    func evaluate(_ processes: [ProcInfo]) -> ProcInfo? {
        let now = Date()
        var found: ProcInfo?
        for p in processes {
            if p.cpu >= Self.busyThreshold, !ignored.contains(p.name), !ProcessList.isProtected(p) {
                let since = busySince[p.id] ?? now
                busySince[p.id] = since
                if found == nil, !reported.contains(p.id), now.timeIntervalSince(since) >= Self.duration {
                    reported.insert(p.id)
                    found = p
                }
            } else if p.cpu < Self.calmThreshold {
                busySince[p.id] = nil
                reported.remove(p.id)
            }
        }
        let live = Set(processes.map(\.id))
        busySince = busySince.filter { live.contains($0.key) }
        reported.formIntersection(live)
        return found
    }
}

/// macOS notifications with Quit / Ignore actions for runaway processes.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onQuit: ((pid_t) -> Void)?
    var onIgnore: ((String) -> Void)?
    var onOpen: (() -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let quit = UNNotificationAction(identifier: "QUIT", title: "Quit Process", options: [.destructive])
        let ignore = UNNotificationAction(identifier: "IGNORE", title: "Ignore This Process")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "RUNAWAY", actions: [quit, ignore], intentIdentifiers: []),
        ])
    }

    func post(_ alert: MonitorAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = .default
        if let pid = alert.pid, let name = alert.processName {
            content.categoryIdentifier = "RUNAWAY"
            content.userInfo = ["pid": Int(pid), "name": name]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = (info["pid"] as? Int).map { pid_t($0) }
        let name = info["name"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case "QUIT": if let pid { self.onQuit?(pid) }
            case "IGNORE": if let name { self.onIgnore?(name) }
            default: self.onOpen?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
