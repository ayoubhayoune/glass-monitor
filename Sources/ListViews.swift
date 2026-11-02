import SwiftUI
import AppKit

enum Columns {
    static let primary: CGFloat = 72
    static let secondary: CGFloat = 60
    static let action: CGFloat = 18
}

extension ListTab {
    var primaryTitle: String {
        switch self {
        case .memory: "MEMORY"
        case .disk: "DISK I/O"
        case .network: "NETWORK"
        case .energy: "ENERGY"
        default: "CPU"
        }
    }

    var secondaryTitle: String { self == .cpu ? "MEMORY" : "CPU" }

    func primary(_ x: RowMetrics, memTotal: UInt64) -> (text: String, fraction: Double) {
        switch self {
        case .memory: (bytes(Double(x.mem)), Double(x.mem) / Double(memTotal) * 4)
        case .disk: x.disk.map { (rate($0), $0 / 50_000_000) } ?? ("—", 0)
        case .network: x.net.map { (rate($0), $0 / 5_000_000) } ?? ("—", 0)
        case .energy: x.energy.map { (String(format: "%.1f", $0), $0 / 50) } ?? ("…", 0)
        default: (String(format: "%.1f%%", x.cpu), x.cpu / 100)
        }
    }

    func secondary(_ x: RowMetrics) -> String {
        self == .cpu ? bytes(Double(x.mem)) : String(format: "%.1f%%", x.cpu)
    }
}

// MARK: - Tabs

struct TabBar: View {
    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ListTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.3)) { m.tab = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(m.tab == tab ? Color.primary : Color.secondary)
                        .background {
                            if m.tab == tab {
                                Capsule().fill(.primary.opacity(0.12)).matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if m.tab.isProcessMetric {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { prefs.groupByApp.toggle() }
                } label: {
                    Image(systemName: prefs.groupByApp ? "square.stack.3d.up.fill" : "list.bullet")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(prefs.groupByApp ? "Grouped by app — click to list every process" : "Every process — click to group by app")
            }
        }
    }
}

// MARK: - Kill controls

struct KillButton: View {
    let key: String
    @ObservedObject var m: Monitor
    let visible: Bool
    let enabled: Bool
    let name: String

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                m.confirmKey = key
                m.adminKey = nil
            }
        } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red.opacity(0.85))
        .opacity(visible && enabled ? 1 : 0)
        .disabled(!enabled)
        .help(enabled ? "Kill \(name)" : "System-critical — can't be killed here")
        .frame(width: Columns.action)
    }
}

struct ConfirmKill: View {
    let key: String
    @ObservedObject var m: Monitor
    let onKill: (_ force: Bool) -> Void
    var onAdmin: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if m.adminKey == key, let onAdmin {
                PillButton("Kill as admin", .red, action: onAdmin)
                PillButton("Cancel") { withAnimation(.snappy(duration: 0.25)) { m.adminKey = nil } }
            } else {
                PillButton("Quit", .orange) { onKill(false) }
                PillButton("Force", .red) { onKill(true) }
                PillButton("Cancel") { withAnimation(.snappy(duration: 0.25)) { m.confirmKey = nil } }
            }
        }
    }
}

private let slideIn = AnyTransition.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity)

// MARK: - Processes

struct ProcessListView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 4) {
            if m.tab == .energy { batterySummary }
            if m.tab == .network { connectionSummary }
            HStack(spacing: 8) {
                Text(prefs.groupByApp ? "APP" : "PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                Text(m.tab.primaryTitle).foregroundStyle(.primary).frame(width: Columns.primary, alignment: .trailing)
                Text(m.tab.secondaryTitle).frame(width: Columns.secondary, alignment: .trailing)
                Color.clear.frame(width: Columns.action, height: 1)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    if prefs.groupByApp {
                        ForEach(m.topGroups) { groupRows($0) }
                    } else {
                        ForEach(m.topProcesses) { processRow($0, indent: 0) }
                    }
                }
            }
            .scrollIndicators(.never)

            if let note = footnote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footnote: String? {
        switch m.tab {
        case .disk: "macOS only reports disk activity for your own processes; others show —"
        case .network: "Per-process traffic measured with nettop"
        case .energy: "Energy Impact as reported by macOS, the same figure as Activity Monitor's Energy tab"
        default: nil
        }
    }

    private func summaryStrip(_ symbol: String, _ items: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(items.joined(separator: "  ·  ")).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var batterySummary: some View {
        if let p = m.power {
            summaryStrip(p.onBattery ? "battery.50percent" : "powerplug.fill", batteryItems(p))
        } else {
            summaryStrip("powerplug.fill", ["No battery · energy use per app"])
        }
    }

    private func batteryItems(_ p: PowerInfo) -> [String] {
        var items = [p.percent.map { "\($0)%" } ?? "Battery",
                     p.onBattery ? String(format: "On battery · %.1f W", p.watts) : (p.charging ? "Charging" : "On power")]
        if let minutes = p.minutesRemaining {
            items.append("\(duration(Double(minutes) * 60)) \(p.onBattery ? "left" : "to full")")
        }
        if let capacity = m.battery?.maxCapacity { items.append("Health \(capacity)%") }
        if let cycles = m.battery?.cycles { items.append("\(cycles) cycles") }
        return items
    }

    @ViewBuilder
    private var connectionSummary: some View {
        if let w = m.wifi {
            summaryStrip("wifi", [w.ssid ?? "Wi-Fi", "\(w.quality) signal (\(w.rssi) dBm)",
                                  String(format: "%.0f Mb/s link", w.txRate), w.ip.map { "IP \($0)" } ?? "No IP"])
        } else if let ip = m.wiredIP {
            summaryStrip("cable.connector", ["Wired", "IP \(ip)"])
        } else {
            summaryStrip("wifi.slash", ["Not connected"])
        }
    }

    @ViewBuilder
    private func groupRows(_ g: AppGroup) -> some View {
        if g.processes.count == 1, let p = g.processes.first {
            processRow(p, indent: 0)
        } else {
            let key = "g:\(g.id)"
            let open = m.openGroups.contains(g.id)
            let canKill = !g.processes.contains(where: ProcessList.isProtected)
            HoverRow(icon: AnyView(HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                ProcessIcon(bundlePath: g.bundlePath, user: g.user)
            }), title: g.name, subtitle: "\(g.processes.count) processes") { hovering in
                trailing(key: key, metrics: g.metrics, hovering: hovering, canKill: canKill, name: g.name,
                         onKill: { m.kill(group: g, force: $0) }, onAdmin: nil)
            }
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { m.toggleGroup(g.id) } }

            if open {
                ForEach(g.processes.prefix(20)) { processRow($0, indent: 38) }
            }
        }
    }

    private func processRow(_ p: ProcInfo, indent: CGFloat) -> some View {
        let key = "p:\(p.id)"
        let subtitle = p.appName.map { $0 != p.name ? "\($0) · \(p.id)" : "\(p.user) · \(p.id)" } ?? "\(p.user) · \(p.id)"
        return HoverRow(leading: 8 + indent, icon: AnyView(ProcessIcon(bundlePath: p.bundlePath, user: p.user)),
                        title: p.name, subtitle: subtitle) { hovering in
            trailing(key: key, metrics: p.metrics, hovering: hovering, canKill: !ProcessList.isProtected(p), name: p.name,
                     onKill: { m.kill(p, force: $0) }, onAdmin: { m.adminKill(pid: p.id, name: p.name) })
        }
    }

    private func trailing(key: String, metrics: RowMetrics, hovering: Bool, canKill: Bool, name: String,
                          onKill: @escaping (Bool) -> Void, onAdmin: (() -> Void)?) -> some View {
        Group {
            if m.confirmKey == key || m.adminKey == key {
                ConfirmKill(key: key, m: m, onKill: onKill, onAdmin: onAdmin)
            } else {
                let primary = m.tab.primary(metrics, memTotal: m.memTotal)
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(primary.text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        Capsule().fill(.primary.opacity(0.1)).frame(width: 44, height: 3).overlay(alignment: .leading) {
                            let f = min(max(primary.fraction, 0), 1)
                            Capsule().fill(level(f)).frame(width: max(3, 44 * f), height: 3)
                        }
                    }
                    .frame(width: Columns.primary, alignment: .trailing)
                    Text(m.tab.secondary(metrics))
                        .font(.system(size: 11, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: Columns.secondary, alignment: .trailing)
                    KillButton(key: key, m: m, visible: hovering, enabled: canKill, name: name)
                }
            }
        }
        .transition(slideIn)
    }
}

// MARK: - Dev

struct DevView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                laravelSection

                SectionTitle("DOCKER CONTAINERS").padding(.top, 6)
                switch m.docker {
                case .loading:
                    ProgressView().controlSize(.small).padding(8)
                case .unavailable(let reason):
                    note(reason)
                case .ready(let containers):
                    if containers.isEmpty { note("No containers") }
                    ForEach(containers) { containerRow($0) }
                }

                SectionTitle("LOCAL SERVERS · LISTENING PORTS").padding(.top, 6)
                if m.servers.isEmpty { note("Nothing listening") }
                ForEach(m.servers) { serverRow($0) }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var laravelSection: some View {
        HStack {
            SectionTitle("LARAVEL · ERRORS IN THE LAST 24 H")
            if m.scanningLaravel { ProgressView().controlSize(.mini) }
            Button { m.scanLaravel() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .help("Scan logs again")
        }
        if let projects = m.laravel {
            let failing = projects.filter { $0.errors > 0 }
            if failing.isEmpty { note(projects.isEmpty ? "No Laravel projects found" : "No errors in \(projects.count) projects") }
            ForEach(failing.prefix(8)) { laravelRow($0) }
            if !failing.isEmpty, projects.count > failing.count {
                note("\(projects.count - failing.count) other projects quiet")
            }
        }
    }

    private func laravelRow(_ p: LaravelProject) -> some View {
        let containers = p.containers(in: m.docker)
        let running = containers.filter(\.running).count
        let icon = Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .frame(width: 22, height: 22)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        let when = p.lastErrorDate.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return HoverRow(icon: AnyView(icon), title: p.name, subtitle: (p.lastError ?? "") + when) { hovering in
            Group {
                if hovering {
                    HStack(spacing: 6) {
                        if running > 0 { PillButton("Restart") { m.restartContainers(p) } }
                        PillButton("Open Log") { m.openLog(p) }
                    }
                } else {
                    HStack(spacing: 8) {
                        if !containers.isEmpty {
                            Text("\(running)/\(containers.count) up").foregroundStyle(.secondary)
                        }
                        Text("\(p.errors)\(p.truncated ? "+" : "")")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                }
            }
            .transition(slideIn)
        }
        .help(p.lastError ?? p.name)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func containerRow(_ c: DockerContainer) -> some View {
        let key = "c:\(c.id)"
        let icon = Image(systemName: "shippingbox.fill")
            .font(.system(size: 11))
            .foregroundStyle(c.running ? Color.blue : Color.secondary)
            .frame(width: 22, height: 22)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(c.running ? Color.green : Color.gray).frame(width: 7, height: 7).offset(x: 2, y: 2)
            }
        return HoverRow(icon: AnyView(icon), title: c.name,
                        subtitle: [c.project, c.image].filter { !$0.isEmpty }.joined(separator: " · ")) { hovering in
            Group {
                if m.confirmKey == key {
                    HStack(spacing: 6) {
                        PillButton("Stop", .red) { m.dockerAction("stop", c) }
                        PillButton("Cancel") { withAnimation(.snappy(duration: 0.25)) { m.confirmKey = nil } }
                    }
                } else if hovering {
                    HStack(spacing: 6) {
                        if c.running {
                            PillButton("Restart") { m.dockerAction("restart", c) }
                            PillButton("Stop", .orange) { withAnimation(.snappy(duration: 0.25)) { m.confirmKey = key } }
                        } else {
                            PillButton("Start", .green) { m.dockerAction("start", c) }
                        }
                    }
                } else if c.running {
                    HStack(spacing: 8) {
                        Text(c.cpu).frame(width: Columns.primary, alignment: .trailing)
                        Text(c.memory).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                } else {
                    Text(c.status).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .transition(slideIn)
        }
    }

    private func serverRow(_ s: ListeningServer) -> some View {
        let key = "s:\(s.id)"
        let title = s.appName.map { $0 == s.name ? s.name : "\(s.name) · \($0)" } ?? s.name
        return HoverRow(icon: AnyView(ProcessIcon(bundlePath: s.bundlePath, user: "", symbol: "server.rack")),
                        title: title, subtitle: "PID \(s.id)") { hovering in
            Group {
                if m.confirmKey == key || m.adminKey == key {
                    ConfirmKill(key: key, m: m, onKill: { m.kill(pid: s.id, name: s.name, force: $0, key: key) },
                                onAdmin: { m.adminKill(pid: s.id, name: s.name) })
                } else {
                    HStack(spacing: 6) {
                        if hovering, let port = s.ports.first {
                            PillButton("Open :\(port)") { m.open(port: port) }
                        } else {
                            Text(s.ports.prefix(3).map { ":\($0)" }.joined(separator: " "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        KillButton(key: key, m: m, visible: hovering, enabled: true, name: s.name)
                    }
                }
            }
            .transition(slideIn)
        }
        .contextMenu { portMenu(s, key: key) }
    }

    /// Right-click: free a port that's "already in use" without hunting for the process.
    @ViewBuilder
    private func portMenu(_ s: ListeningServer, key: String) -> some View {
        let ports = s.ports.map { ":\($0)" }.joined(separator: " ")
        Button("Free \(ports) — Quit \(s.name)") { m.kill(pid: s.id, name: s.name, force: false, key: key) }
        Button("Force Kill \(s.name)") { m.kill(pid: s.id, name: s.name, force: true, key: key) }
        Divider()
        ForEach(s.ports, id: \.self) { port in
            Button("Open http://localhost:\(port)") { m.open(port: port) }
        }
        ForEach(s.ports, id: \.self) { port in
            Button("Copy http://localhost:\(port)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://localhost:\(port)", forType: .string)
            }
        }
    }
}

// MARK: - Clean

struct CleanView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Cleaned items go to the Trash — empty it to actually free the space.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { m.scanClean() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(m.scanningClean)
                .help("Measure again")
            }
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(m.cleanItems) { cleanRow($0) }

                    SectionTitle("PROJECT node_modules").padding(.top, 6)
                    if m.scanningProjects {
                        ProgressView().controlSize(.small).padding(8)
                    } else if let found = m.nodeModules {
                        if found.isEmpty {
                            Text("None found").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(found.prefix(30)) { cleanRow($0) }
                    } else {
                        PillButton("Scan project folders") { m.scanProjects() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func cleanRow(_ item: CleanItem) -> some View {
        let key = "clean:\(item.id)"
        let icon = Image(systemName: item.symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        return HoverRow(icon: AnyView(icon), title: item.title, subtitle: item.detail) { hovering in
            Group {
                if m.confirmKey == key {
                    HStack(spacing: 6) {
                        PillButton(item.actionTitle, .red) { m.clean(item) }
                        PillButton("Cancel") { withAnimation(.snappy(duration: 0.25)) { m.confirmKey = nil } }
                    }
                } else {
                    HStack(spacing: 8) {
                        if let size = item.sizeText {
                            Text(size).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(item.size > 1_073_741_824 ? Color.orange : Color.primary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        if hovering, item.size > 0 || item.sizeText == "—" {
                            PillButton(item.actionTitle == "Show" ? "Show" : "Clean") {
                                if case .reveal = item.action {
                                    m.clean(item)
                                } else {
                                    withAnimation(.snappy(duration: 0.25)) { m.confirmKey = key }
                                }
                            }
                        }
                    }
                }
            }
            .transition(slideIn)
        }
    }
}
