import Foundation
import IOKit
import CoreWLAN

struct ThermalInfo: Equatable {
    var cpu: Double?
    var gpu: Double?
    /// Current speed of each fan in rpm (empty on fanless Macs).
    var fans: [Int]
}

/// CPU/GPU temperatures from the Apple Silicon HID temperature sensors. The IOHIDEventSystem API is private,
/// so it's looked up at runtime: if a macOS update removes it, temperatures just aren't shown.
final class TemperatureSensors {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private var client: AnyObject?
    private var sensors: [(name: String, service: AnyObject)] = []
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        // Usage page 0xff00 / usage 5 = temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        sensors = services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, service)
        }
        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    /// CPU = average of the CPU cluster sensors (falls back to the SoC die sensors); GPU = average of the GPU sensors.
    func read() -> (cpu: Double?, gpu: Double?) {
        guard let copyEvent, let getFloat else { return (nil, nil) }
        var clusters: [Double] = [], dies: [Double] = [], gpus: [Double] = []
        for sensor in sensors {
            guard let event = copyEvent(sensor.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = getFloat(event, Self.temperatureField)
            guard celsius > 5, celsius < 130 else { continue }
            let name = sensor.name.lowercased()
            if name.contains("gpu") { gpus.append(celsius) }
            else if name.contains("pacc") || name.contains("eacc") { clusters.append(celsius) }
            else if name.contains("tdie") { dies.append(celsius) }
        }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return (average(clusters) ?? average(dies), average(gpus))
    }
}

/// Read-only access to the System Management Controller, used for fan speeds.
final class SMC {
    // Mirrors the kernel's SMCKeyData_t (80 bytes); `padding` reproduces the C alignment after keyInfo.
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
    private struct Params {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard MemoryLayout<Params>.size == 80, IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
        else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout Params) -> Params? {
        var output = Params()
        var outputSize = MemoryLayout<Params>.stride
        let result = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<Params>.stride,
                                               &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    /// Value of a numeric SMC key, decoding the common Apple Silicon and Intel formats.
    func value(_ key: String) -> Double? {
        var input = Params()
        input.key = Self.fourCC(key)
        input.data8 = Self.readKeyInfo
        guard let info = call(&input)?.keyInfo, info.dataSize > 0 else { return nil }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readKey
        guard let output = call(&input) else { return nil }
        let b = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) }
        switch info.dataType {
        case Self.fourCC("flt ") where b.count >= 4:
            let raw = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: raw))
        case Self.fourCC("fpe2") where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case Self.fourCC("ui8 ") where b.count >= 1: return Double(b[0])
        case Self.fourCC("ui16") where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        default: return nil
        }
    }

    /// GPU temperature keys across Apple Silicon generations (M1 Pro/Max, M2, M3); missing keys are skipped.
    private static let gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j", "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]

    /// Average of the GPU sensors the SMC exposes, for Macs whose HID sensors have no GPU entry.
    func gpuTemperature() -> Double? {
        let readings = Self.gpuKeys.compactMap { value($0) }.filter { $0 > 5 && $0 < 130 }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    func fanSpeeds() -> [Int] {
        let count = Int(value("FNum") ?? 0)
        return (0..<min(count, 4)).compactMap { i in
            value("F\(i)Ac").flatMap { $0.isFinite && $0 >= 0 && $0 < 20_000 ? Int($0) : nil }
        }
    }
}

struct WiFiInfo: Equatable {
    /// nil unless the app has Location permission (macOS hides network names otherwise).
    let ssid: String?
    let rssi: Int
    let noise: Int
    let txRate: Double
    let ip: String?

    var quality: String {
        switch rssi {
        case (-55)...: "Excellent"
        case -67..<(-55): "Good"
        case -75..<(-67): "Fair"
        default: "Weak"
        }
    }
}

enum NetworkInfo {
    /// Current Wi-Fi link, or nil when Wi-Fi is off or not connected.
    static func wifi() -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        return WiFiInfo(ssid: interface.ssid(), rssi: rssi, noise: interface.noiseMeasurement(),
                        txRate: interface.transmitRate(), ip: ipv4(of: interface.interfaceName ?? "en0"))
    }

    static func wifiInterfaceName() -> String? { CWWiFiClient.shared().interface()?.interfaceName }

    /// First IPv4 address of a wired "en" interface, for when Wi-Fi isn't the connection.
    static func wiredIP(excluding wifiInterface: String?) -> String? {
        addresses().first { $0.name.hasPrefix("en") && $0.name != wifiInterface }?.ip
    }

    static func ipv4(of name: String) -> String? {
        addresses().first { $0.name == name }?.ip
    }

    private static func addresses() -> [(name: String, ip: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(String, String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            result.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        return result
    }
}
