import Foundation
import Network

/// Measures TCP connect latency to a node's server endpoint — an offline reachability probe
/// for when the core isn't running. This is transport-level only (no proxy handshake), so it
/// ranks node reachability rather than proxied round-trip time.
public struct TCPLatencyProber: Sendable {
    public init() {}

    public func latencyMS(host: String, port: Int, timeout: TimeInterval = 3) async -> Int? {
        guard (1...65_535).contains(port), !host.isEmpty else {
            return nil
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )

        let gate = ResumeGate()
        let start = Date()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() {
                        let elapsed = Int((Date().timeIntervalSince(start) * 1000).rounded())
                        connection.cancel()
                        continuation.resume(returning: max(elapsed, 1))
                    }
                case .waiting, .failed, .cancelled:
                    // NWConnection parks refused/unreachable connections in .waiting and
                    // retries; a latency probe wants the immediate verdict instead.
                    if gate.claim() {
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The connection's state handler, our timeout, and our own cancel all race to finish the
    /// probe; the continuation must resume exactly once.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed {
                return false
            }
            claimed = true
            return true
        }
    }
}
