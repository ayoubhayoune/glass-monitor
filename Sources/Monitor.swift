import AppKit
import SwiftUI
import Combine

enum ListTab: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, energy, dev, clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        case .dev: "Dev"
        case .clean: "Clean"
        }
    }

    var isProcessMetric: Bool { self != .dev && self != .clean }
}

/// Graph time windows. Each keeps `points` averages of `bucket` 1.5 s samples, so every range costs the same to draw.
enum HistoryRange: String, CaseIterable, Identifiable {
    case m30, h2, h12, d1

    static let points = 150

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m30: "30m"
        case .h2: "2h"
        case .h12: "12h"
        case .d1: "1d"
        }
    }

    var title: String {
        switch self {
        case .m30: "last 30 minutes"
        case .h2: "last 2 hours"
        case .h12: "last 12 hours"
        case .d1: "last day"
        }
    }

    /// 150 × bucket × 1.5 s = the window length (12 s, 48 s, 4.8 min and 9.6 min per point).
    var bucket: Int {
        switch self {
        case .m30: 8
        case .h2: 32
        case .h12: 192
        case .d1: 384
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// One averaged series per history range, fed with 1.5 s samples.
/// Saved to disk so the long ranges survive restarts; time the app wasn't running is stored as NaN (a gap in the graph).
struct Series: Codable {
    private var points = [[Double]](repeating: [], count: HistoryRange.allCases.count)
    private var sums = [Double](repeating: 0, count: HistoryRange.allCases.count)
    private var counts = [Int](repeating: 0, count: HistoryRange.allCases.count)
    /// Per point, the label given with its highest sample, e.g. the app using the most CPU at the peak ("" = none).
    private var labels = [[String]](repeating: [], count: HistoryRange.allCases.count)
    private var peaks = [Double](repeating: -.infinity, count: HistoryRange.allCases.count)
    private var peakLabels = [String](repeating: "", count: HistoryRange.allCases.count)

    mutating func add(_ value: Double, label: String? = nil) {
        for range in HistoryRange.allCases {
            let i = range.index
            sums[i] += value
            counts[i] += 1
            if let label, value >= peaks[i] {
                peaks[i] = value
                peakLabels[i] = label
            }
            guard counts[i] == range.bucket else { continue }
            append(sums[i] / Double(counts[i]), label: peakLabels[i], at: i)
            resetBucket(i)
        }
    }

    private mutating func append(_ value: Double, label: String, at i: Int) {
        points[i].append(value)
        labels[i].append(label)
        if points[i].count > HistoryRange.points {
            points[i].removeFirst(points[i].count - HistoryRange.points)
        }
        if labels[i].count > points[i].count { labels[i].removeFirst(labels[i].count - points[i].count) }
    }

    private mutating func resetBucket(_ i: Int) {
        sums[i] = 0
        counts[i] = 0
        peaks[i] = -.infinity
        peakLabels[i] = ""
    }

    /// Accounts for time the app wasn't sampling: whole missing points become NaN gaps and the partial bucket is dropped.
    mutating func skip(seconds: Double) {
        for range in HistoryRange.allCases {
            let i = range.index
            let missing = Int(seconds / (Double(range.bucket) * 1.5))
            guard missing > 0 else { continue }
            for _ in 0..<min(missing, HistoryRange.points) { append(.nan, label: "", at: i) }
            resetBucket(i)
        }
    }

    /// Completed points plus the bucket still filling, so the newest point moves live.
    func values(_ range: HistoryRange) -> [Double] {
        let i = range.index
        guard counts[i] > 0 else { return points[i] }
        return Array((points[i] + [sums[i] / Double(counts[i])]).suffix(HistoryRange.points))
    }

    /// Labels aligned one-to-one with `values(range)`.
    func labels(_ range: HistoryRange) -> [String] {
        let i = range.index
        var result = labels[i]
        if result.count < points[i].count { result.insert(contentsOf: Array(repeating: "", count: points[i].count - result.count), at: 0) }
        guard counts[i] > 0 else { return result }
        return Array((result + [peakLabels[i]]).suffix(HistoryRange.points))
    }
}

struct Histories: Codable {
    var cpu = Series(), gpu = Series(), memory = Series(), swap = Series(), io = Series(), network = Series()

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass Monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private struct Saved: Codable {
        let savedAt: Date
        let histories: Histories
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(Saved(savedAt: Date(), histories: self)) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    /// The saved history, with the time since it was saved turned into gaps.
    static func load() -> Histories {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? Data(contentsOf: file),
              let saved = try? decoder.decode(Saved.self, from: data) else { return Histories() }
        var h = saved.histories
        let gap = max(Date().timeIntervalSince(saved.savedAt), 0)
        for path in [\Histories.cpu, \.gpu, \.memory, \.swap, \.io, \.network] as [WritableKeyPath<Histories, Series>] {
            h[keyPath: path].skip(seconds: gap)
        }
        return h
    }
}

final class Monitor: ObservableObject {
    /// Swap is "bad" in absolute terms, not as a share of its dynamically growing file.
    static let swapScale = 8.0 * 1_073_741_824

    let prefs = Prefs.shared

    // Wired up by the window controller.
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onSnapToCorner: (() -> Void)?
    var onShutDown: (() -> Void)?
    var onAlert: ((MonitorAlert) -> Void)?

    @Published var screenName = UserDefaults.standard.string(forKey: "screenName") {
        didSet { UserDefaults.standard.set(screenName, forKey: "screenName") }
    }

    // MARK: Live system stats
    @Published private(set) var cpu = 0.0
    @Published private(set) var cpuUser = 0.0
    @Published private(set) var cpuSystem = 0.0
    @Published private(set) var gpu: Double?
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memTotal: UInt64 = 1
    @Published private(set) var memCompressed: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var pressure = MemoryPressure.normal
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var power: PowerInfo?
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 1
    @Published private(set) var readRate = 0.0
    @Published private(set) var writeRate = 0.0
    @Published private(set) var netIn = 0.0
    @Published private(set) var netOut = 0.0
    @Published private(set) var history = Histories.load()
    /// Glass Monitor's own cost: CPU (one core = 100%, including the ps/lsof helpers it runs) and memory footprint.
    @Published private(set) var selfCPU = 0.0
    @Published private(set) var selfMemory: UInt64 = 0
    /// Read only while the panel is open.
    @Published private(set) var thermalInfo: ThermalInfo?
    @Published private(set) var wifi: WiFiInfo?
    @Published private(set) var wiredIP: String?

    // MARK: Panel state
    @Published var expanded = false {
        didSet {
            confirmKey = nil
            adminKey = nil
            if expanded { refreshTab() }
        }
    }
    @Published var tab = ListTab.cpu {
        didSet {
            confirmKey = nil
            updateRows()
            refreshTab()
        }
    }
    @Published private(set) var topProcesses: [ProcInfo] = []
    @Published private(set) var topGroups: [AppGroup] = []
    @Published private(set) var openGroups = Set<String>()
    @Published private(set) var docker = DockerState.loading
    @Published private(set) var servers: [ListeningServer] = []
    @Published private(set) var cleanItems: [CleanItem] = []
    @Published private(set) var nodeModules: [CleanItem]?
    @Published private(set) var scanningClean = false
    @Published private(set) var scanningProjects = false
    @Published var confirmKey: String?
    @Published var adminKey: String?
    @Published private(set) var message: String?
    @Published private(set) var alert: MonitorAlert?

    var memFraction: Double { Double(memUsed) / Double(memTotal) }
    var diskFraction: Double { Double(diskUsed) / Double(max(diskTotal, 1)) }
    var swapLevel: Double { min(1, Double(swapUsed) / Self.swapScale) }
    var swapColor: Color { swapUsed < 512 << 20 ? .green : swapUsed < 3 << 30 ? .orange : .red }

    private var processes: [ProcInfo] = []
    private let sampler = ProcessSampler()
    private let runaway = RunawayDetector()
    private var lastPressureAlert = Date.distantPast
    private var pressureWarningSince: Date?
    private var lastPressureWarning = Date.distantPast
    private var lastDiskAlert = Date.distantPast
    /// Top app by CPU / memory at the last process sample, stored with each graph point.
    private var cpuCulprit: String?
    private var memoryCulprit: String?
    private lazy var temperatures = TemperatureSensors()
    private lazy var smc = SMC()
    private var lastTicks: CPUTicks?
    private var lastIO: (read: UInt64, write: UInt64)?
    private var lastNet: (received: UInt64, sent: UInt64)?
    private var lastSample = Date()
    private var lastSelf: (cpuTime: Double, at: Date)?
    private var tickCount = 0
    private var timer: Timer?
    /// Background jobs in flight (main-thread only), so slow tools never pile up.
    private var busy = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        prefs.$groupByApp.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateRows() }
        }.store(in: &cancellables)
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func saveHistory() { history.save() }

    // MARK: Sampling

    private func tick() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastSample), 0.1)
        lastSample = now

        if let ticks = SystemStats.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                let total = Double(ticks.total - last.total)
                cpuUser = Double((ticks.user + ticks.nice) - (last.user + last.nice)) / total
                cpuSystem = Double(ticks.system - last.system) / total
                cpu = min(1, cpuUser + cpuSystem)
            }
            lastTicks = ticks
        }

        let mem = SystemStats.memory()
        (memUsed, memTotal, memCompressed) = (mem.used, max(mem.total, 1), mem.compressed)
        (swapUsed, swapTotal) = (mem.swapUsed, mem.swapTotal)
        pressure = SystemStats.memoryPressure()
        thermal = ProcessInfo.processInfo.thermalState
        gpu = SystemStats.gpuUtilization()
        // Free space is costly to compute (purgeable space accounting) and changes slowly.
        if tickCount % 20 == 0 {
            (diskUsed, diskTotal) = SystemStats.disk()
            checkDiskSpace()
        }
        if tickCount % 4 == 0 { power = SystemStats.power() }

        let io = SystemStats.diskIOBytes()
        // Counters drop when a disk or disk image is detached; skip that sample instead of wrapping around.
        if let last = lastIO, io.read >= last.read, io.write >= last.write {
            readRate = Double(io.read - last.read) / dt
            writeRate = Double(io.write - last.write) / dt
        }
        lastIO = io

        let net = SystemStats.networkBytes()
        if let last = lastNet, net.received >= last.received, net.sent >= last.sent {
            netIn = Double(net.received - last.received) / dt
            netOut = Double(net.sent - last.sent) / dt
        }
        lastNet = net

        history.cpu.add(cpu, label: cpuCulprit)
        history.gpu.add(gpu ?? 0)
        history.memory.add(memFraction, label: memoryCulprit)
        history.swap.add(swapLevel)
        history.io.add(readRate + writeRate)
        history.network.add(netIn + netOut)

        checkPressure()
        if tickCount % 4 == 0 { measureSelf(now) }
        if tickCount % 40 == 39 { history.save() } // once a minute; a crash loses at most a minute

        let showingProcesses = expanded && tab.isProcessMetric
        if showingProcesses ? tickCount % 2 == 0 : (prefs.alertsEnabled && tickCount % 4 == 0) {
            sampleProcesses()
        }
        if expanded && tab == .dev && tickCount % 4 == 0 { refreshDev() }
        if expanded && tickCount % 4 == 2 { readSensors() }
        tickCount += 1
    }

    /// Temperatures, fans and (on the Network tab) the Wi-Fi link — only while the panel is open.
    private func readSensors() {
        guard busy.insert("sensors").inserted else { return }
        let wantNetwork = tab == .network
        DispatchQueue.global(qos: .utility).async { [self] in
            let temps = temperatures.read()
            let info = ThermalInfo(cpu: temps.cpu, gpu: temps.gpu ?? smc?.gpuTemperature(), fans: smc?.fanSpeeds() ?? [])
            let wifi = wantNetwork ? NetworkInfo.wifi() : nil
            let wired = wantNetwork ? NetworkInfo.wiredIP(excluding: NetworkInfo.wifiInterfaceName()) : nil
            DispatchQueue.main.async { [self] in
                thermalInfo = info
                if wantNetwork {
                    self.wifi = wifi
                    wiredIP = wired
                }
                busy.remove("sensors")
            }
        }
    }

    /// Averaged over 4 ticks (6 s) so the figure doesn't jump with every ps run.
    private func measureSelf(_ now: Date) {
        let usage = SystemStats.selfUsage()
        selfMemory = usage.memory
        if let last = lastSelf, usage.cpuTime >= last.cpuTime {
            selfCPU = (usage.cpuTime - last.cpuTime) / max(now.timeIntervalSince(last.at), 0.1)
        }
        lastSelf = (usage.cpuTime, now)
    }

    private func refreshTab() {
        guard expanded else { return }
        switch tab {
        case .dev: refreshDev()
        case .clean: if cleanItems.isEmpty { scanClean() }
        default: sampleProcesses()
        }
        readSensors()
    }

    private func sampleProcesses() {
        guard busy.insert("ps").inserted else { return }
        sampler.sample(network: expanded && tab == .network, energy: expanded && tab == .energy) { [weak self] list in
            guard let self else { return }
            busy.remove("ps")
            processes = list
            updateRows()
            updateCulprits()
            if prefs.alertsEnabled, let p = runaway.evaluate(list) {
                raise(MonitorAlert(title: "\(p.appName ?? p.name) is using \(Int(p.cpu))% CPU",
                                   detail: "\(p.name) (PID \(p.id)) has been busy for over 2 minutes",
                                   pid: p.id, processName: p.name))
            }
        }
    }

    private func sortValue(_ x: RowMetrics) -> Double {
        switch tab {
        case .memory: Double(x.mem)
        case .disk: x.disk ?? 0
        case .network: x.net ?? 0
        case .energy: x.energy ?? 0
        default: x.cpu
        }
    }

    private var appGroups: [AppGroup] {
        Dictionary(grouping: processes, by: \.groupKey).map { AppGroup(id: $0.key, processes: $0.value) }
    }

    private func updateCulprits() {
        let groups = appGroups
        cpuCulprit = groups.max { $0.metrics.cpu < $1.metrics.cpu }
            .map { "\($0.name) · \(String(format: "%.0f", $0.metrics.cpu))% CPU" }
        memoryCulprit = groups.max { $0.metrics.mem < $1.metrics.mem }
            .map { "\($0.name) · \(bytes(Double($0.metrics.mem)))" }
    }

    private func updateRows() {
        guard tab.isProcessMetric else { return }
        let ranked = processes.sorted { sortValue($0.metrics) > sortValue($1.metrics) }
        topProcesses = Array(ranked.prefix(14))
        topGroups = Array(Dictionary(grouping: ranked, by: \.groupKey)
            .map { AppGroup(id: $0.key, processes: $0.value) }
            .sorted { sortValue($0.metrics) > sortValue($1.metrics) }
            .prefix(14))
    }

    func toggleGroup(_ id: String) {
        if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) }
    }

    // MARK: Killing

    func kill(_ p: ProcInfo, force: Bool) {
        kill(pid: p.id, name: p.name, force: force, key: "p:\(p.id)")
    }

    func kill(pid: pid_t, name: String, force: Bool, key: String) {
        confirmKey = nil
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 {
            flash("\(force ? "Force killed" : "Quit") \(name)")
            processes.removeAll { $0.id == pid }
            servers.removeAll { $0.id == pid }
            updateRows()
            refreshSoon()
        } else if errno == EPERM {
            adminKey = key
            flash("\(name) belongs to another user — needs admin")
        } else {
            flash("Couldn't kill \(name): \(String(cString: strerror(errno)))")
        }
    }

    func kill(group: AppGroup, force: Bool) {
        confirmKey = nil
        let failed = group.processes.filter { Darwin.kill($0.id, force ? SIGKILL : SIGTERM) != 0 }.count
        flash(failed == 0 ? "\(force ? "Force killed" : "Quit") \(group.name)"
                          : "\(group.name): \(failed) process(es) need admin — expand to kill them")
        refreshSoon()
    }

    /// Asks macOS for an admin password (system dialog) and force-kills the process.
    func adminKill(pid: pid_t, name: String) {
        adminKey = nil
        flash(Shell.admin("/bin/kill -9 \(pid)") ? "Force killed \(name)" : "Admin kill cancelled")
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            tab == .dev ? refreshDev() : sampleProcesses()
        }
    }

    // MARK: Alerts

    private func checkPressure() {
        let now = Date()
        pressureWarningSince = pressure == .normal ? nil : (pressureWarningSince ?? now)
        guard prefs.alertsEnabled else { return }
        // Only group the process list when an alert actually fires; this runs every tick.
        func biggestText() -> String? {
            appGroups.max { $0.metrics.mem < $1.metrics.mem }
                .map { "Biggest: \($0.name) · \(bytes(Double($0.metrics.mem)))" }
        }

        if pressure == .critical, now.timeIntervalSince(lastPressureAlert) > 600 {
            lastPressureAlert = now
            raise(MonitorAlert(title: "Memory pressure is critical",
                               detail: biggestText() ?? "Close some apps to free memory",
                               pid: nil, processName: nil))
        } else if pressure == .warning, let since = pressureWarningSince, now.timeIntervalSince(since) >= 180,
                  now.timeIntervalSince(lastPressureWarning) > 3600, now.timeIntervalSince(lastPressureAlert) > 600 {
            // Earlier heads-up: pressure has stayed at "warning" for 3 minutes (at most once an hour).
            lastPressureWarning = now
            let swap = swapUsed > 0 ? " · swap \(bytes(Double(swapUsed)))" : ""
            raise(MonitorAlert(title: "Memory is getting tight",
                               detail: (biggestText() ?? "Close some apps to free memory") + swap,
                               pid: nil, processName: nil))
        }
    }

    /// Warns when the startup disk drops below 15 GB free (at most every 6 hours).
    private func checkDiskSpace() {
        let free = diskTotal - diskUsed
        guard prefs.alertsEnabled, diskTotal > 1, free < 15 * 1_073_741_824,
              Date().timeIntervalSince(lastDiskAlert) > 6 * 3600 else { return }
        lastDiskAlert = Date()
        raise(MonitorAlert(title: "Disk almost full · \(bytes(Double(max(free, 0)))) free",
                           detail: "Clear caches and old project files in the Clean tab",
                           pid: nil, processName: nil, opensTab: .clean))
    }

    private func raise(_ newAlert: MonitorAlert) {
        withAnimation(.smooth(duration: 0.35)) { alert = newAlert }
        onAlert?(newAlert)
    }

    /// Debug aid: `--test-alert` shows a sample banner.
    func showTestAlert() {
        raise(MonitorAlert(title: "Python is using 97% CPU", detail: "Python (PID 1234) has been busy for over 2 minutes",
                           pid: 1234, processName: "Python"))
    }

    func dismissAlert() {
        withAnimation(.smooth(duration: 0.3)) { alert = nil }
    }

    func quitAlertProcess() {
        guard let a = alert, let pid = a.pid else { return }
        kill(pid: pid, name: a.processName ?? "process", force: false, key: "alert")
        dismissAlert()
    }

    func ignore(processName: String) {
        runaway.ignore(processName)
        flash("Won't alert about \(processName) again")
        if alert?.processName == processName { dismissAlert() }
    }

    func show(tab newTab: ListTab) {
        withAnimation(.snappy(duration: 0.25)) { expanded = true }
        tab = newTab
        dismissAlert()
    }

    // MARK: Dev

    func refreshDev() {
        guard busy.insert("dev").inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = Docker.state()
            let servers = Servers.listening()
            DispatchQueue.main.async {
                self.docker = state
                self.servers = servers
                self.busy.remove("dev")
            }
        }
    }

    func dockerAction(_ action: String, _ container: DockerContainer) {
        confirmKey = nil
        flash("\(action.capitalized)ing \(container.name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Docker.perform(action, container.id)
            DispatchQueue.main.async {
                self.flash(ok ? "\(container.name): \(action) done" : "\(container.name): \(action) failed")
                self.refreshDev()
            }
        }
    }

    func open(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Clean

    func scanClean() {
        guard busy.insert("clean").inserted else { return }
        scanningClean = true
        let items = Cleaner.items()
        cleanItems = items
        DispatchQueue.global(qos: .utility).async {
            let measured = items.map(Cleaner.measure)
            DispatchQueue.main.async {
                self.cleanItems = measured
                self.scanningClean = false
                self.busy.remove("clean")
            }
        }
    }

    func scanProjects() {
        guard busy.insert("projects").inserted else { return }
        scanningProjects = true
        DispatchQueue.global(qos: .utility).async {
            let found = Cleaner.nodeModules()
            DispatchQueue.main.async {
                self.nodeModules = found
                self.scanningProjects = false
                self.busy.remove("projects")
            }
        }
    }

    func clean(_ item: CleanItem) {
        confirmKey = nil
        if case .reveal = item.action { _ = Cleaner.perform(item); return }
        flash("Cleaning \(item.title)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Cleaner.perform(item)
            DispatchQueue.main.async {
                self.flash(result)
                self.nodeModules?.removeAll { $0.id == item.id }
                self.scanClean()
            }
        }
    }

    // MARK: Tools

    func run(_ action: SystemAction) {
        let ok = action.needsAdmin ? Shell.admin(action.command) : Shell.run("/bin/sh", ["-c", action.command]).status == 0
        flash(ok ? action.doneMessage : "\(action.title) cancelled")
    }

    private func flash(_ text: String) {
        guard !text.isEmpty else { return }
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }
}
