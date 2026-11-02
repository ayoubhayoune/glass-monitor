import Foundation
import CoreWLAN

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
