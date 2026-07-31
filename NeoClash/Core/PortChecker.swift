import Darwin
import Foundation

public struct PortChecker: Sendable {
    public init() {}

    public func isAvailable(host: String, port: Int) -> Bool {
        guard (1...65_535).contains(port) else {
            return false
        }

        let normalizedHost = RuntimePorts.normalizedControllerHost(host)
        var hints = addrinfo()
        hints.ai_flags = normalizedHost.isEmpty ? AI_PASSIVE | AI_NUMERICSERV : AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var addresses: UnsafeMutablePointer<addrinfo>?
        let lookupResult = getaddrinfo(
            normalizedHost.isEmpty ? nil : normalizedHost,
            String(port),
            &hints,
            &addresses
        )
        guard lookupResult == 0, let addresses else {
            return false
        }
        defer { freeaddrinfo(addresses) }

        var candidate: UnsafeMutablePointer<addrinfo>? = addresses
        while let address = candidate?.pointee {
            defer { candidate = address.ai_next }

            let socketDescriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            guard socketDescriptor >= 0 else {
                continue
            }
            defer { close(socketDescriptor) }

            var value: Int32 = 1
            setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &value,
                socklen_t(MemoryLayout<Int32>.size)
            )

            if Darwin.bind(socketDescriptor, address.ai_addr, address.ai_addrlen) == 0 {
                return true
            }
        }
        return false
    }
}
