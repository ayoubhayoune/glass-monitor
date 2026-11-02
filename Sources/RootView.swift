import SwiftUI
import AppKit

struct RootView: View {
    static let pillHeight: CGFloat = 38
    static let alertHeight: CGFloat = 52
    static let expandedSize = CGSize(width: 540, height: 744)

    // Edge card: the pill items in a grid of fixed cells.
    private static let cell = CGSize(width: 66, height: 34)
    private static let cellSpacing = CGSize(width: 10, height: 8)
    private static let cardPadding: CGFloat = 13

    private static func edgeColumns(_ items: [PillItem]) -> Int { items.count + 1 > 2 ? 2 : 1 }

    static func edgeCardSize(_ items: [PillItem]) -> CGSize {
        let columns = edgeColumns(items)
        let cells = items.count + 1 // the last cell is the shut-down button
        let rows = (cells + columns - 1) / columns
        return CGSize(width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * cellSpacing.width + cardPadding * 2,
                      height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * cellSpacing.height + cardPadding * 2)
    }

    static func pillWidth(_ items: [PillItem]) -> CGFloat {
        106 + items.reduce(0) { $0 + $1.width } + CGFloat(items.count) * 10
    }

    /// The edge card only shows while collapsed with no alert; an alert brings the full pill back.
    static func showsEdgeTab(expanded: Bool, alert: Bool, minimized: Bool) -> Bool {
        minimized && !expanded && !alert
    }

    /// Single source of truth for the panel size; the window controller resizes the panel to match.
    static func size(expanded: Bool, alert: Bool, items: [PillItem], minimized: Bool = false) -> CGSize {
        if showsEdgeTab(expanded: expanded, alert: alert, minimized: minimized) { return edgeCardSize(items) }
        let pill = pillWidth(items)
        let extra = alert ? alertHeight : 0
        return expanded
            ? CGSize(width: max(expandedSize.width, pill), height: expandedSize.height + extra)
            : CGSize(width: max(pill, alert ? 420 : 0), height: pillHeight + extra)
    }

    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared

    private var edgeCardShown: Bool {
        Self.showsEdgeTab(expanded: m.expanded, alert: m.alert != nil, minimized: prefs.minimized)
    }

    var body: some View {
        VStack(spacing: 0) {
            if edgeCardShown {
                edgeCard
            } else {
                header
            }
            if let alert = m.alert {
                AlertBanner(alert: alert, m: m).transition(.opacity)
            }
            if m.expanded {
                details
                    .frame(width: Self.size(expanded: true, alert: false, items: prefs.pillItems).width)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10)).animation(.smooth(duration: 0.35).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        // Fill the window: the controller animates its frame, and the glass follows it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: m.expanded ? 24 : edgeCardShown ? 22 : 19,
                                                    style: .continuous))
        .animation(.smooth(duration: 0.35), value: m.expanded)
        .contextMenu { SettingsMenu(m: m) }
    }

    // MARK: Pill

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(prefs.pillItems) { chip($0).frame(width: $0.width, alignment: .leading) }
            Spacer(minLength: 0)
            if !m.expanded {
                Button { prefs.minimized = true } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10, height: Self.pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Minimize to the screen edge")
            }
            HideButton(size: 10).frame(height: Self.pillHeight)
            ShutDownButton(m: m, size: 10).frame(height: Self.pillHeight)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(m.expanded ? 180 : 0))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { m.expanded.toggle() } }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in m.onDrag?() }
            .onEnded { _ in m.onDragEnd?() })
        .help("Click to expand · drag to move · ⌥⌘M")
    }

    /// Minimized state: a rounded card on the right screen edge with the pill items in a grid.
    /// Click to restore, drag to move it up or down.
    private var edgeCard: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.cell.width), spacing: Self.cellSpacing.width),
                            count: Self.edgeColumns(prefs.pillItems))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cellSpacing.height) {
            ForEach(prefs.pillItems) { item in
                let v = metric(item)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if let ring = v.ring { Ring(value: ring, color: v.color) }
                        Text(v.label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(v.text)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: Self.cell.width, height: Self.cell.height, alignment: .leading)
            }
            HStack(spacing: 14) {
                HideButton(size: 13)
                ShutDownButton(m: m, size: 13)
            }
            .frame(width: Self.cell.width, height: Self.cell.height, alignment: .leading)
        }
        .padding(Self.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { prefs.minimized = false }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in m.onDrag?() }
            .onEnded { _ in m.onDragEnd?() })
        .help("Click to restore the pill · drag it anywhere · ⌥⌘M opens the panel")
    }

    /// The label, ring and value shown for a pill item (in the pill and in the edge card).
    private func metric(_ item: PillItem) -> (label: String, ring: Double?, color: Color?, text: String) {
        switch item {
        case .cpu: ("CPU", m.cpu, nil, percent(m.cpu))
        case .gpu: ("GPU", m.gpu ?? 0, nil, m.gpu.map(percent) ?? "—")
        case .ram: ("RAM", m.memFraction, m.pressure.color, percent(m.memFraction))
        case .swap: ("SWAP", m.swapLevel, m.swapColor, gigabytes(m.swapUsed))
        case .disk: ("DISK", m.diskFraction, nil, percent(m.diskFraction))
        case .net: ("NET", nil, nil, "↓\(shortBytes(m.netIn)) ↑\(shortBytes(m.netOut))")
        }
    }

    private func chip(_ item: PillItem) -> some View {
        let v = metric(item)
        return MetricChip(label: v.label, ring: v.ring, color: v.color, text: v.text)
    }

    // MARK: Expanded

    private var details: some View {
        VStack(spacing: 10) {
            statusStrip
            tiles
            TabBar(m: m)
            Group {
                switch m.tab {
                case .dev: DevView(m: m)
                case .clean: CleanView(m: m)
                default: ProcessListView(m: m)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            status(m.pressure.color, "circle.fill", "Memory: \(m.pressure.title)")
            status(m.thermal.color, "thermometer.medium", thermalText)
                .help(thermalHelp)
            if let fan = m.thermalInfo?.fans.max(), fan > 0 {
                status(.secondary, "fan.fill", "\(fan) rpm")
            }
            if let power = m.power {
                status(.secondary, power.onBattery ? "battery.75percent" : "powerplug.fill", powerText(power))
            }
            Spacer(minLength: 0)
            historyToggle
        }
        .font(.system(size: 10.5, weight: .medium))
    }

    private func status(_ color: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 6 : 10)).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary).truncationMode(.tail)
        }
        .lineLimit(1)
    }

    /// "Cool · 58° / 52°" (CPU / GPU), or just the thermal state when the sensors can't be read.
    private var thermalText: String {
        let temps = [m.thermalInfo?.cpu, m.thermalInfo?.gpu].compactMap { $0 }.map { "\(Int($0.rounded()))°" }
        return temps.isEmpty ? m.thermal.title : "\(m.thermal.title) · \(temps.joined(separator: " / "))"
    }

    private var thermalHelp: String {
        var parts = ["Thermal state: \(m.thermal.title)"]
        if let c = m.thermalInfo?.cpu { parts.append("CPU \(Int(c.rounded())) °C") }
        if let g = m.thermalInfo?.gpu { parts.append("GPU \(Int(g.rounded())) °C") }
        if let fans = m.thermalInfo?.fans, !fans.isEmpty { parts.append("Fans " + fans.map { "\($0) rpm" }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func powerText(_ p: PowerInfo) -> String {
        let battery = p.percent.map { " · \($0)%" } ?? ""
        if p.onBattery { return String(format: "%.1f W", p.watts) + battery }
        return (p.charging ? "Charging" : "On power") + battery
    }

    private var historyToggle: some View {
        HStack(spacing: 0) {
            ForEach(HistoryRange.allCases) { range in
                Button {
                    withAnimation(.smooth(duration: 0.3)) { prefs.historyRange = range }
                } label: {
                    Text(range.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(prefs.historyRange == range ? Color.primary : Color.secondary)
                        .background(prefs.historyRange == range ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Graphs show the \(range.title)")
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        // Never squeeze the range buttons; the status items to the left truncate instead.
        .fixedSize()
        .layoutPriority(1)
    }

    private var tiles: some View {
        let range = prefs.historyRange
        let capacity = HistoryRange.points
        let step = Double(range.bucket) * 1.5
        let gpuHistory = m.history.gpu.values(range)
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MetricTile(title: "CPU", value: percent(m.cpu), tint: level(m.cpu),
                           history: m.history.cpu.values(range), capacity: capacity,
                           lines: ["User \(percent(m.cpuUser))", "System \(percent(m.cpuSystem))"],
                           secondsPerPoint: step, labels: m.history.cpu.labels(range))
                MetricTile(title: "GPU", value: m.gpu.map(percent) ?? "—", tint: level(m.gpu ?? 0),
                           history: gpuHistory, capacity: capacity,
                           lines: ["Graphics, video & ML", "Peak \(percent(gpuHistory.filter(\.isFinite).max() ?? 0))"],
                           secondsPerPoint: step)
                MetricTile(title: "MEMORY", value: percent(m.memFraction), tint: m.pressure.color,
                           history: m.history.memory.values(range), capacity: capacity,
                           lines: ["\(bytes(Double(m.memUsed))) of \(bytes(Double(m.memTotal)))",
                                   "Pressure: \(m.pressure.title)"],
                           secondsPerPoint: step, labels: m.history.memory.labels(range))
            }
            GridRow {
                MetricTile(title: "SWAP", value: m.swapUsed == 0 ? "None" : bytes(Double(m.swapUsed)), tint: m.swapColor,
                           history: m.history.swap.values(range), capacity: capacity,
                           lines: [m.swapTotal == 0 ? "Not swapping" : "of \(bytes(Double(m.swapTotal))) file",
                                   "Compressed \(bytes(Double(m.memCompressed)))"],
                           secondsPerPoint: step, format: { bytes($0 * Monitor.swapScale) })
                MetricTile(title: "DISK", value: rate(m.readRate + m.writeRate), tint: .blue,
                           history: m.history.io.values(range), capacity: capacity, autoScaleFloor: 1_000_000,
                           lines: ["↓\(rate(m.readRate)) ↑\(rate(m.writeRate))",
                                   "\(bytes(Double(m.diskTotal - m.diskUsed))) free · \(percent(m.diskFraction)) full"],
                           secondsPerPoint: step, format: rate)
                MetricTile(title: "NETWORK", value: rate(m.netIn + m.netOut), tint: .teal,
                           history: m.history.network.values(range), capacity: capacity, autoScaleFloor: 100_000,
                           lines: ["↓ \(rate(m.netIn))", "↑ \(rate(m.netOut))"],
                           secondsPerPoint: step, format: rate)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(m.message ?? "Glass Monitor: \(String(format: "%.1f", m.selfCPU * 100))% CPU · \(bytes(Double(m.selfMemory)))  ·  ⌥⌘M toggles")
                .font(.system(size: 10))
                .foregroundStyle(m.message == nil ? .secondary : .primary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: m.message)
            Spacer(minLength: 4)
            Menu {
                ForEach(SystemAction.allCases) { action in
                    Button { m.run(action) } label: {
                        Label(action.title + (action.needsAdmin ? "…" : ""), systemImage: action.symbol)
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Label("Open Activity Monitor", systemImage: "chart.bar.xaxis")
                }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver.fill").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct AlertBanner: View {
    let alert: MonitorAlert
    @ObservedObject var m: Monitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(alert.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let name = alert.processName, alert.pid != nil {
                PillButton("Quit", .red) { m.quitAlertProcess() }
                PillButton("Ignore") { m.ignore(processName: name) }
            } else {
                PillButton(alert.opensTab == .clean ? "Clean" : "Show") { m.show(tab: alert.opensTab) }
            }
            Button { m.dismissAlert() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: RootView.alertHeight - 8)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

struct SettingsMenu: View {
    @ObservedObject var m: Monitor
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Text("Glass Monitor uses \(String(format: "%.1f", m.selfCPU * 100))% CPU · \(bytes(Double(m.selfMemory)))")
        Divider()
        Menu("Show in Pill") {
            ForEach(PillItem.allCases) { item in
                Toggle(item.title, isOn: Binding(get: { prefs.pillItems.contains(item) }, set: { _ in prefs.toggle(item) }))
            }
        }
        Picker("Opacity", selection: $prefs.opacity) {
            Text("100%").tag(1.0)
            Text("85%").tag(0.85)
            Text("70%").tag(0.7)
            Text("50%").tag(0.5)
        }
        Toggle("Click-Through (hold ⌥ to interact)", isOn: $prefs.clickThrough)
        Toggle("Hide in Full-Screen Apps", isOn: $prefs.hideInFullScreen)
        Toggle("Hide from Screen Sharing & Recordings", isOn: $prefs.hideFromSharing)
        Toggle("Runaway Process Alerts", isOn: $prefs.alertsEnabled)
        Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) }))
        Divider()
        Menu("Move to Screen") {
            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                Button(screen.localizedName) {
                    m.screenName = screen.localizedName
                    m.onSnapToCorner?()
                }
            }
        }
        Button("Snap to Top-Right") { m.onSnapToCorner?() }
        Toggle("Minimize to Screen Edge", isOn: $prefs.minimized)
        Button("Hide to Menu Bar") { prefs.hidden = true }
        Divider()
        Button("Toggle Panel  (⌥⌘M)") { withAnimation(.snappy(duration: 0.25)) { m.expanded.toggle() } }
        Button("Quit Glass Monitor") { NSApp.terminate(nil) }
        Button("Shut Down (until I open it again)") { m.onShutDown?() }
    }
}

/// Eye icon: hides the pill into a menu bar icon; Glass Monitor keeps monitoring and alerting.
struct HideButton: View {
    let size: CGFloat

    var body: some View {
        Button { Prefs.shared.hidden = true } label: {
            Image(systemName: "eye.slash")
                .font(.system(size: size, weight: .bold))
                .padding(.horizontal, 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Hide to the menu bar (keeps running) · click the menu bar icon or ⌥⌘M to bring it back")
    }
}

/// Power icon in the pill, the panel header and the edge card. The first click arms it (turns red),
/// a second click within 3 s shuts Glass Monitor down until it's opened again.
struct ShutDownButton: View {
    @ObservedObject var m: Monitor
    let size: CGFloat
    @State private var armed = false

    var body: some View {
        Button {
            if armed { m.onShutDown?() } else { arm() }
        } label: {
            Image(systemName: "power").font(.system(size: size, weight: .bold))
            .padding(.horizontal, 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(armed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .help(armed ? "Click again to shut down Glass Monitor (open it again from Spotlight)"
                    : "Shut down Glass Monitor until you open it again")
    }

    private func arm() {
        armed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
    }
}
