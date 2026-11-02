import Foundation
import Combine

enum PillItem: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, swap, disk, temp, net

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .swap: "SWAP"
        case .disk: "DISK"
        case .temp: "TEMP"
        case .net: "NET"
        }
    }

    /// Fixed chip widths keep the pill from jittering as numbers change.
    var width: CGFloat {
        switch self {
        case .cpu, .gpu: 72
        case .ram: 74
        case .disk, .temp: 80
        case .swap: 86
        case .net: 118
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published var pillItems: [PillItem] { didSet { defaults.set(pillItems.map(\.rawValue), forKey: "pillItems") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var clickThrough: Bool { didSet { defaults.set(clickThrough, forKey: "clickThrough") } }
    @Published var hideFromSharing: Bool { didSet { defaults.set(hideFromSharing, forKey: "hideFromSharing") } }
    @Published var hideInFullScreen: Bool { didSet { defaults.set(hideInFullScreen, forKey: "hideInFullScreen") } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var graphRange: GraphRange { didSet { defaults.set(graphRange.rawValue, forKey: "graphRange") } }
    /// Collapsed to a small card docked on the right edge of the screen (or wherever it's dragged).
    @Published var minimized: Bool { didSet { defaults.set(minimized, forKey: "minimized") } }
    /// The pill is hidden and a menu bar icon brings it back; monitoring and alerts keep running.
    @Published var hidden: Bool { didSet { defaults.set(hidden, forKey: "hidden") } }
    @Published var groupByApp: Bool { didSet { defaults.set(groupByApp, forKey: "groupByApp") } }
    // Alert thresholds; 0 = off.
    @Published var ramAlert: Double { didSet { defaults.set(ramAlert, forKey: "ramAlert") } }
    @Published var swapAlertGB: Double { didSet { defaults.set(swapAlertGB, forKey: "swapAlertGB") } }
    @Published var diskAlert: Double { didSet { defaults.set(diskAlert, forKey: "diskAlert") } }
    @Published var tempAlert: Double { didSet { defaults.set(tempAlert, forKey: "tempAlert") } }

    private init() {
        pillItems = (defaults.stringArray(forKey: "pillItems") ?? ["cpu", "gpu", "ram", "swap", "disk"])
            .compactMap(PillItem.init(rawValue:))
        opacity = defaults.object(forKey: "opacity") as? Double ?? 1
        clickThrough = defaults.bool(forKey: "clickThrough")
        hideFromSharing = defaults.object(forKey: "hideFromSharing") as? Bool ?? true
        hideInFullScreen = defaults.object(forKey: "hideInFullScreen") as? Bool ?? true
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        graphRange = defaults.string(forKey: "graphRange").flatMap(GraphRange.init(rawValue:)) ?? .m30
        minimized = defaults.bool(forKey: "minimized")
        hidden = defaults.bool(forKey: "hidden")
        groupByApp = defaults.object(forKey: "groupByApp") as? Bool ?? true
        ramAlert = defaults.object(forKey: "ramAlert") as? Double ?? 0
        swapAlertGB = defaults.object(forKey: "swapAlertGB") as? Double ?? 8
        diskAlert = defaults.object(forKey: "diskAlert") as? Double ?? 0.95
        tempAlert = defaults.object(forKey: "tempAlert") as? Double ?? 0
    }

    /// Adds or removes a pill item, keeping the canonical order and at least one item.
    func toggle(_ item: PillItem) {
        if pillItems.contains(item) {
            if pillItems.count > 1 { pillItems.removeAll { $0 == item } }
        } else {
            pillItems = PillItem.allCases.filter { pillItems.contains($0) || $0 == item }
        }
    }
}
