import AppKit

struct RowMetrics {
    var cpu: Double
    var mem: UInt64
    var disk: Double?
    var net: Double?
    /// macOS "Energy Impact" (the Energy tab of Activity Monitor); only sampled while the Energy tab is open.
    var energy: Double?
}

struct ProcInfo: Identifiable {
    let id: pid_t
    let name: String
    let user: String
    let cpu: Double
    let memBytes: UInt64
    /// Bytes/s; nil when macOS doesn't let us read it (other users' processes) or on the first sample.
    var diskRate: Double?
    var netRate: Double?
    var energy: Double?
    let appName: String?
    let bundlePath: String?

    var groupKey: String { bundlePath ?? "proc:\(name)" }
    var metrics: RowMetrics { RowMetrics(cpu: cpu, mem: memBytes, disk: diskRate, net: netRate, energy: energy) }
}

/// All processes belonging to one app bundle (e.g. Chrome and its helpers), or sharing a name.
struct AppGroup: Identifiable {
    let id: String
    let processes: [ProcInfo]
    let metrics: RowMetrics

    init(id: String, processes: [ProcInfo]) {
        self.id = id
        self.processes = processes
        metrics = processes.reduce(into: RowMetrics(cpu: 0, mem: 0)) { total, p in
            total.cpu += p.cpu
            total.mem += p.memBytes
            if let d = p.diskRate { total.disk = (total.disk ?? 0) + d }
            if let n = p.netRate { total.net = (total.net ?? 0) + n }
            if let e = p.energy { total.energy = (total.energy ?? 0) + e }
        }
    }

    var name: String { processes.first?.appName ?? processes.first?.name ?? "?" }
    var bundlePath: String? { processes.first?.bundlePath }
    var user: String { processes.first?.user ?? "" }
}

enum ProcessList {
    static let protectedNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    static func isProtected(_ p: ProcInfo) -> Bool {
        protectedNames.contains(p.name) || p.id == getpid()
    }

    /// The outermost .app bundle a process runs from, so "Google Chrome Helper" resolves to Google Chrome.
    static func identity(of pid: pid_t) -> (appName: String?, bundlePath: String?) {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return (nil, nil) }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return (nil, nil) }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return (FileManager.default.displayName(atPath: bundle), bundle)
    }

    /// Total bytes read + written by a process; nil without permission (other users' processes).
    static func diskBytes(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        // Wrapping add: some processes report garbage counters near UInt64.max, and a plain + traps.
        return result == 0 ? info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten : nil
    }
}

/// Main-thread icon cache keyed by bundle path.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func app(_ bundlePath: String) -> NSImage {
        if let cached = cache[bundlePath] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[bundlePath] = image
        return image
    }
}

/// Samples the process table off the main thread, turning cumulative disk/network counters into rates.
final class ProcessSampler {
    private let queue = DispatchQueue(label: "glassmonitor.sampler", qos: .utility)
    private var identities: [pid_t: (appName: String?, bundlePath: String?)] = [:]
    private var lastDisk: [pid_t: UInt64] = [:]
    private var lastDiskTime: Date?
    private var lastNet: [pid_t: UInt64] = [:]
    private var lastNetTime: Date?
    /// `top` takes a second and real CPU, so energy figures are reused for a few seconds between runs.
    private var energyCache: (at: Date, values: [pid_t: Double])?

    func sample(network: Bool, energy: Bool, completion: @escaping ([ProcInfo]) -> Void) {
        queue.async {
            let list = self.collect(network: network, energy: energy)
            DispatchQueue.main.async { completion(list) }
        }
    }

    private func collect(network: Bool, energy: Bool) -> [ProcInfo] {
        let now = Date()
        let diskInterval = lastDiskTime.map { now.timeIntervalSince($0) }
        let netTotals = network ? nettop() : [:]
        var energyImpact: [pid_t: Double] = [:]
        if energy {
            if let cache = energyCache, now.timeIntervalSince(cache.at) < 6 {
                energyImpact = cache.values
            } else {
                energyImpact = energyImpacts()
                energyCache = (now, energyImpact)
            }
        }
        let netInterval = network ? lastNetTime.map { now.timeIntervalSince($0) } : nil

        var disk: [pid_t: UInt64] = [:]
        var result: [ProcInfo] = []
        for row in ps() {
            let identity = identities[row.pid] ?? ProcessList.identity(of: row.pid)
            identities[row.pid] = identity

            var diskRate: Double?
            if let total = ProcessList.diskBytes(of: row.pid) {
                disk[row.pid] = total
                if let dt = diskInterval, let previous = lastDisk[row.pid] {
                    diskRate = Double(total &- previous) / dt
                    if total < previous { diskRate = 0 }
                }
            }

            var netRate: Double?
            if let dt = netInterval {
                let total = netTotals[row.pid] ?? 0
                let previous = lastNet[row.pid] ?? total
                netRate = total >= previous ? Double(total - previous) / dt : 0
            }

            result.append(ProcInfo(id: row.pid, name: row.name, user: row.user, cpu: row.cpu, memBytes: row.mem,
                                   diskRate: diskRate, netRate: netRate,
                                   energy: energy ? energyImpact[row.pid] ?? 0 : nil,
                                   appName: identity.appName, bundlePath: identity.bundlePath))
        }

        lastDisk = disk
        lastDiskTime = now
        if network {
            lastNet = netTotals
            lastNetTime = now
        } else {
            lastNetTime = nil
        }
        let live = Set(result.map(\.id))
        identities = identities.filter { live.contains($0.key) }
        return result
    }

    private func ps() -> [(pid: pid_t, cpu: Double, mem: UInt64, user: String, name: String)] {
        Shell.run("/bin/ps", ["-Aco", "pid=,pcpu=,rss=,user=,comm="]).output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), pid > 1,
                  let cpu = Double(parts[1]), let rssKB = UInt64(parts[2]) else { return nil }
            return (pid, cpu, rssKB * 1024, String(parts[3]), parts[4].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Per-process energy impact from `top` (the same figure as Activity Monitor). The first `top` sample has no
    /// rates yet, so take two samples a second apart and read the second table.
    private func energyImpacts() -> [pid_t: Double] {
        let output = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "400", "-o", "power", "-stats", "pid,power"]).output
        guard let table = output.components(separatedBy: "PID").last else { return [:] }
        var result: [pid_t: Double] = [:]
        for line in table.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let power = Double(parts[1]) else { continue }
            result[pid] = power
        }
        return result
    }

    /// Per-process bytes in + out from `nettop`, keyed by pid ("name.pid,in,out," lines).
    private func nettop() -> [pid_t: UInt64] {
        let output = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]).output
        var totals: [pid_t: UInt64] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3, let dot = columns[0].lastIndex(of: "."),
                  let pid = Int32(columns[0][columns[0].index(after: dot)...]) else { continue }
            totals[pid, default: 0] &+= (UInt64(columns[1]) ?? 0) &+ (UInt64(columns[2]) ?? 0)
        }
        return totals
    }
}
