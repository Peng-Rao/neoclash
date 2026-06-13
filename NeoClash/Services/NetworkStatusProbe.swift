import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public struct NetworkEgressInfo: Equatable, Sendable {
    public var ipAddress: String
    public var countryCode: String?

    public init(ipAddress: String, countryCode: String? = nil) {
        self.ipAddress = ipAddress
        self.countryCode = countryCode
    }
}

public struct NetworkStatusProbe: Sendable {
    private struct RouteInfo: Sendable {
        var interfaceName: String?
        var routerIPAddress: String?
    }

    private struct WiFiDetails: Sendable {
        var ssid: String?
        var band: String?
        var isWiFi: Bool
    }

    private struct EgressPayload: Decodable {
        var ip: String?
        var country: String?
        var countryCode: String?
        var country_code: String?
        var country_iso: String?
    }

    public init() {}

    public func snapshot() async -> NetworkStatusSnapshot {
        let route = Self.activeIPv4Route()
        let interfaceName = route.interfaceName ?? Self.firstActiveIPv4InterfaceName()
        let wifi = Self.wifiDetails(interfaceName: interfaceName)

        async let internetLatency = httpLatency(
            url: URL(string: "https://www.apple.com/library/test/success.html"),
            timeout: 3
        )
        async let dnsLatency = Self.dnsLookupLatency(host: "www.apple.com")
        async let routerLatency = routerLatency(routerIPAddress: route.routerIPAddress)
        async let egress = egressInfo()

        let egressInfo = await egress
        return NetworkStatusSnapshot(
            internetLatencyMS: await internetLatency,
            dnsLatencyMS: await dnsLatency,
            routerLatencyMS: await routerLatency,
            interfaceName: interfaceName,
            interfaceKind: Self.interfaceKind(interfaceName: interfaceName, wifi: wifi),
            serviceName: Self.serviceName(interfaceName: interfaceName, wifi: wifi),
            wifiSSID: wifi.ssid,
            wifiBand: wifi.band,
            localIPAddress: interfaceName.flatMap(Self.localIPv4Address(interfaceName:)),
            routerIPAddress: route.routerIPAddress,
            egressIPAddress: egressInfo?.ipAddress,
            egressCountryCode: egressInfo?.countryCode,
            updatedAt: Date()
        )
    }

    public static func parseEgressPayload(_ data: Data) -> NetworkEgressInfo? {
        guard let payload = try? JSONDecoder().decode(EgressPayload.self, from: data),
              let ip = payload.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            return nil
        }

        let countryCode = [
            payload.country,
            payload.countryCode,
            payload.country_code,
            payload.country_iso
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        .first { !$0.isEmpty }

        return NetworkEgressInfo(ipAddress: ip, countryCode: countryCode)
    }

    public static func latencyMilliseconds(start: Date, end: Date = Date()) -> Int {
        max(1, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

    private static func activeIPv4Route() -> RouteInfo {
        guard let store = SCDynamicStoreCreate(nil, "NeoClashNetworkStatus" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return RouteInfo()
        }

        return RouteInfo(
            interfaceName: value["PrimaryInterface"] as? String,
            routerIPAddress: value["Router"] as? String
        )
    }

    private static func firstActiveIPv4InterfaceName() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }
            return String(cString: interface.ifa_name)
        }
        return nil
    }

    private static func localIPv4Address(interfaceName: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            guard String(cString: interface.ifa_name) == interfaceName,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var socketAddress = address.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &socketAddress,
                socklen_t(socketAddress.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    private static func wifiDetails(interfaceName: String?) -> WiFiDetails {
        let client = CWWiFiClient.shared()
        let interface = interfaceName.flatMap { client.interface(withName: $0) } ?? client.interface()
        guard let interface else {
            return WiFiDetails(ssid: nil, band: nil, isWiFi: false)
        }

        let matchesRequestedInterface = interfaceName == nil || interface.interfaceName == interfaceName
        guard matchesRequestedInterface else {
            return WiFiDetails(ssid: nil, band: nil, isWiFi: false)
        }

        return WiFiDetails(
            ssid: interface.ssid(),
            band: bandName(interface.wlanChannel()?.channelBand),
            isWiFi: true
        )
    }

    private static func bandName(_ band: CWChannelBand?) -> String? {
        guard let band else {
            return nil
        }
        switch band {
        case .band2GHz:
            return "2.4GHz"
        case .band5GHz:
            return "5GHz"
        case .band6GHz:
            return "6GHz"
        default:
            return nil
        }
    }

    private static func interfaceKind(interfaceName: String?, wifi: WiFiDetails) -> NetworkInterfaceKind {
        if wifi.isWiFi {
            return .wifi
        }
        guard let interfaceName else {
            return .unknown
        }
        if interfaceName == "lo0" {
            return .loopback
        }
        if interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("tun") || interfaceName.hasPrefix("tap") {
            return .tunnel
        }
        if interfaceName.hasPrefix("en") {
            return .ethernet
        }
        return .other
    }

    private static func serviceName(interfaceName: String?, wifi: WiFiDetails) -> String? {
        let kind = interfaceKind(interfaceName: interfaceName, wifi: wifi)
        guard kind != .unknown else {
            return nil
        }
        return kind.displayName
    }

    private static func dnsLookupLatency(host: String) async -> Int? {
        await Task.detached(priority: .utility) {
            let start = Date()
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result {
                freeaddrinfo(result)
            }
            guard status == 0 else {
                return nil
            }
            return latencyMilliseconds(start: start)
        }.value
    }

    private func routerLatency(routerIPAddress: String?) async -> Int? {
        guard let routerIPAddress,
              let url = URL(string: "http://\(routerIPAddress)") else {
            return nil
        }
        return await httpLatency(url: url, timeout: 1.5)
    }

    private func httpLatency(url: URL?, timeout: TimeInterval) async -> Int? {
        guard let url else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<500).contains(httpResponse.statusCode) else {
                return nil
            }
            return Self.latencyMilliseconds(start: start)
        } catch {
            return nil
        }
    }

    private func egressInfo() async -> NetworkEgressInfo? {
        let endpoints = [
            "https://ipinfo.io/json",
            "https://ifconfig.co/json"
        ]
        .compactMap(URL.init(string:))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for url in endpoints {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let egress = Self.parseEgressPayload(data) else {
                    continue
                }
                return egress
            } catch {
                continue
            }
        }
        return nil
    }
}
