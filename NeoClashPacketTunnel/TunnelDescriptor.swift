import Darwin

enum TunnelDescriptor {
    // From <net/if_utun.h> and <sys/sys_domain.h>, which the iOS SDK does not expose to Swift.
    private static let controlProtocol: Int32 = 2 // SYSPROTO_CONTROL
    private static let interfaceNameOption: Int32 = 2 // UTUN_OPT_IFNAME
    private static let highestDescriptor: Int32 = 1_024

    /// NEPacketTunnelProvider has no public API for its utun descriptor, so find the open socket
    /// that answers to the utun interface name option.
    static func find() -> Int32? {
        for descriptor in 0...highestDescriptor {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            let result = getsockopt(descriptor, controlProtocol, interfaceNameOption, &name, &length)
            let bytes = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            if result == 0, String(decoding: bytes, as: UTF8.self).hasPrefix("utun") {
                return descriptor
            }
        }
        return nil
    }
}
