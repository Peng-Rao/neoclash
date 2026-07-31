import Darwin
import Foundation

public struct CoreStartRequest: Sendable {
    public var coreURL: URL
    public var runtimeDirectory: URL
    public var runtimeConfigURL: URL
    public var manifest: CoreManifest?
    public var ports: RuntimePorts
    public var secret: String
    public var readinessTimeout: TimeInterval
    public var validateConfiguration: Bool
    public var validationTimeout: TimeInterval

    public init(
        coreURL: URL,
        runtimeDirectory: URL,
        runtimeConfigURL: URL,
        manifest: CoreManifest? = nil,
        ports: RuntimePorts = RuntimePorts(),
        secret: String,
        readinessTimeout: TimeInterval = 10,
        validateConfiguration: Bool = true,
        validationTimeout: TimeInterval = 8
    ) {
        self.coreURL = coreURL
        self.runtimeDirectory = runtimeDirectory
        self.runtimeConfigURL = runtimeConfigURL
        self.manifest = manifest
        self.ports = ports
        self.secret = secret
        self.readinessTimeout = readinessTimeout
        self.validateConfiguration = validateConfiguration
        self.validationTimeout = validationTimeout
    }
}

public struct CoreLaunchResult: Equatable, Sendable {
    public var version: String
    public var processIdentifier: Int32
}

public enum CoreProcessError: Error, Equatable, LocalizedError {
    case portUnavailable(Int)
    case portCollision(Int)
    case processAlreadyRunning
    case validationFailed(String)
    case readinessTimeout(String)
    case unexpectedExit(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let port):
            "Required port is unavailable: \(port)."
        case .portCollision(let port):
            "The mixed proxy and external controller cannot share port \(port)."
        case .processAlreadyRunning:
            "A core process is already running."
        case .validationFailed(let output):
            "Core configuration validation failed.\n\(Redactor.redact(output))"
        case .readinessTimeout(let output):
            "Core did not become ready before timeout.\n\(Redactor.redact(output))"
        case .unexpectedExit(let output):
            "Core exited unexpectedly.\n\(Redactor.redact(output))"
        }
    }
}

public actor CoreProcessController {
    private let validator: CoreBinaryValidator
    private let portChecker: PortChecker
    private var process: Process?
    private var isStarting = false
    private var activeStartID: UUID?
    private var output = RingBuffer<String>(capacity: 256)

    public init(validator: CoreBinaryValidator = CoreBinaryValidator(), portChecker: PortChecker = PortChecker()) {
        self.validator = validator
        self.portChecker = portChecker
    }

    public var capturedOutput: String {
        output.elements.joined(separator: "\n")
    }

    /// Whether the tracked core child process is still alive. The app's watchdog polls this so an
    /// unexpected core exit (panic, OOM-kill, gvisor crash) is detected and recovered instead of
    /// silently blackholing traffic — in TUN mode a dead core leaves the system unable to route.
    public func isCoreRunning() -> Bool {
        process?.isRunning ?? false
    }

    public func start(_ request: CoreStartRequest) async throws -> CoreLaunchResult {
        if isStarting || process?.isRunning == true {
            throw CoreProcessError.processAlreadyRunning
        }

        let startID = UUID()
        isStarting = true
        activeStartID = startID
        defer {
            isStarting = false
            if activeStartID == startID {
                activeStartID = nil
            }
        }

        try validator.validate(coreURL: request.coreURL, manifest: request.manifest)
        try await waitForPortsAvailable(request)
        try ensureStartIsActive(startID)
        if request.validateConfiguration {
            try await validateConfiguration(request)
            try ensureStartIsActive(startID)
        }

        let launched = try launchProcess(request)
        process = launched

        do {
            let version = try await waitUntilReady(request: request, process: launched)
            try ensureStartIsActive(startID)
            guard process === launched, launched.isRunning else {
                throw CancellationError()
            }
            return CoreLaunchResult(version: version.version, processIdentifier: launched.processIdentifier)
        } catch {
            if process === launched {
                process = nil
                await terminateAndReap(launched)
            }
            throw error
        }
    }

    private func ensureStartIsActive(_ startID: UUID) throws {
        guard activeStartID == startID else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    /// Kills mihomo processes launched against `runtimeDirectoryPath` that this controller is not
    /// tracking — orphans left by a previous crash or force-quit that would otherwise hold ports.
    /// Returns the reaped PIDs.
    public func reapOrphans(runtimeDirectoryPath: String) -> [Int32] {
        let pids = Self.orphanedCorePIDs(
            runtimeDirectoryPath: runtimeDirectoryPath,
            psOutput: Self.runProcessSnapshot(),
            excluding: process?.processIdentifier
        )
        return pids.filter { pid in
            // Revalidate the live PID immediately before signaling. Flattened `ps` command text
            // can make a shell wrapper look like mihomo, and the original process may have exited
            // with its PID reused since the snapshot was captured.
            guard Self.liveExecutableIsMihomo(pid: pid) else {
                return false
            }
            return kill(pid, SIGKILL) == 0
        }
    }

    /// Parses `ps` output for mihomo processes bound to `runtimeDirectoryPath` (which is app-specific,
    /// so this never matches an unrelated user's core), excluding the live PID. Pure for testability.
    public static func orphanedCorePIDs(
        runtimeDirectoryPath: String,
        psOutput: String,
        excluding livePID: Int32? = nil
    ) -> [Int32] {
        psOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2,
                      let pid = Int32(fields[0]) else {
                    return nil
                }
                let command = String(fields[1])
                guard Self.isNeoClashCoreCommand(command, runtimeDirectoryPath: runtimeDirectoryPath) else {
                    return nil
                }
                return pid == livePID ? nil : pid
            }
    }

    private static func isNeoClashCoreCommand(
        _ command: String,
        runtimeDirectoryPath: String
    ) -> Bool {
        // Process.command is flattened text. The first argument begins at the earliest known
        // Mihomo option; everything before it is the executable path (which may itself contain
        // spaces). Requiring the exact basename avoids killing shells or helper processes whose
        // arguments merely mention "mihomo" and our runtime directory.
        let optionStarts = [" -f ", " -d ", " -f=", " -d="]
            .compactMap { command.range(of: $0)?.lowerBound }
        guard let executableEnd = optionStarts.min() else {
            return false
        }
        let executable = command[..<executableEnd]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !executable.contains(" -c ") else {
            return false
        }
        guard URL(fileURLWithPath: executable).lastPathComponent == "mihomo" else {
            return false
        }

        return containsArgument(command, flag: "-d", value: runtimeDirectoryPath)
    }

    private static func containsArgument(_ command: String, flag: String, value: String) -> Bool {
        for prefix in [" \(flag) ", " \(flag)="] {
            var searchStart = command.startIndex
            while let range = command.range(of: prefix, range: searchStart..<command.endIndex) {
                let valueStart = range.upperBound
                guard command[valueStart...].hasPrefix(value) else {
                    searchStart = range.upperBound
                    continue
                }
                let valueEnd = command.index(valueStart, offsetBy: value.count)
                if valueEnd == command.endIndex || command[valueEnd].isWhitespace {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func liveExecutableIsMihomo(pid: Int32) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        if pathLength > 0 {
            return URL(fileURLWithPath: decodeCString(pathBuffer)).lastPathComponent == "mihomo"
        }

        // proc_pidpath can be denied for a setuid-root TUN process. proc_name exposes only the
        // executable name and is sufficient as a safe fallback after the exact runtime-dir match.
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = nameBuffer.withUnsafeMutableBytes { buffer in
            proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        return nameLength > 0 && decodeCString(nameBuffer) == "mihomo"
    }

    private static func decodeCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func runProcessSnapshot() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return ""
        }
        // Drain the pipe before waiting: `ps` output on a busy machine exceeds the 64KB pipe buffer,
        // and reading only after waitUntilExit() would deadlock with ps blocked on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func stop() async {
        // Invalidate an in-flight pre-launch start. `isStarting` stays true until that invocation
        // unwinds so a replacement start cannot overlap it across actor reentrancy points.
        activeStartID = nil
        guard let process else {
            return
        }
        self.process = nil

        await terminateAndReap(process)
    }

    private func terminateAndReap(_ process: Process) async {
        if process.isRunning {
            process.terminate()
            // TUN route teardown can push mihomo's graceful shutdown past a couple of
            // seconds; give it room before escalating.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                await Self.sleepIgnoringCancellation(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Wait for the exit to actually land: returning while the old core still
            // holds its listeners makes the next start() fail its port check.
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                await Self.sleepIgnoringCancellation(nanoseconds: 50_000_000)
            }
        }

        // Foundation normally reaps Process children through its dispatch source. Calling
        // waitUntilExit once `isRunning` is false makes that guarantee explicit without risking
        // an unbounded wait on an uninterruptible process.
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private nonisolated static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        await Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }.value
    }

    /// Polls until the controller and mixed ports are free, or throws `portUnavailable`
    /// after `timeout`. A restart races the previous core's shutdown — a SIGTERM'd mihomo
    /// can hold its listeners for a couple of seconds and a SIGKILL'd one for a beat after
    /// the signal — so a one-shot check misreports a dying core as a foreign port conflict.
    public func waitForPortsAvailable(_ request: CoreStartRequest, timeout: TimeInterval = 4) async throws {
        guard request.ports.mixedPort != request.ports.controllerPort else {
            throw CoreProcessError.portCollision(request.ports.mixedPort)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let blockedPort: Int
            if !portChecker.isAvailable(host: request.ports.controllerHost, port: request.ports.controllerPort) {
                blockedPort = request.ports.controllerPort
            } else if !portChecker.isAvailable(host: "127.0.0.1", port: request.ports.mixedPort) {
                blockedPort = request.ports.mixedPort
            } else {
                return
            }
            guard Date() < deadline else {
                throw CoreProcessError.portUnavailable(blockedPort)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func launchProcess(_ request: CoreStartRequest) throws -> Process {
        output.removeAll()

        let process = Process()
        process.executableURL = request.coreURL
        process.arguments = ["-f", request.runtimeConfigURL.path, "-d", request.runtimeDirectory.path]
        process.currentDirectoryURL = request.runtimeDirectory
        process.environment = [
            "SAFE_PATHS": request.runtimeDirectory.path
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        capture(pipe: stdout)
        capture(pipe: stderr)

        try process.run()
        return process
    }

    private func validateConfiguration(_ request: CoreStartRequest) async throws {
        let process = Process()
        process.executableURL = request.coreURL
        process.arguments = ["-t", "-f", request.runtimeConfigURL.path, "-d", request.runtimeDirectory.path]
        process.currentDirectoryURL = request.runtimeDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Drain while the validator runs. Waiting for exit before reading can deadlock once a large
        // diagnostic fills the kernel pipe buffer and the child blocks trying to write more.
        let outputReader = Task.detached(priority: .utility) {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = Date().addingTimeInterval(request.validationTimeout)
        do {
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await terminateAndReap(process)
            let data = await outputReader.value
            appendOutput(String(data: data, encoding: .utf8) ?? "")
            throw error
        }

        if process.isRunning {
            await terminateAndReap(process)
            let data = await outputReader.value
            let outputText = String(data: data, encoding: .utf8) ?? ""
            appendOutput(outputText)
            let details = outputText.isEmpty ? "" : "\n\(outputText)"
            throw CoreProcessError.validationFailed(
                "Validation timed out after \(request.validationTimeout) seconds.\(details)"
            )
        }

        process.waitUntilExit()
        let data = await outputReader.value
        let outputText = String(data: data, encoding: .utf8) ?? ""
        appendOutput(outputText)
        guard process.terminationStatus == 0 else {
            throw CoreProcessError.validationFailed(outputText)
        }
    }

    private func capture(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task {
                await self?.appendOutput(text)
            }
        }
    }

    private func appendOutput(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            output.append(String(line))
        }
    }

    private func waitUntilReady(request: CoreStartRequest, process: Process) async throws -> MihomoVersion {
        let api = MihomoAPIClient(
            host: request.ports.controllerHost,
            port: request.ports.controllerPort,
            secret: request.secret
        )
        let deadline = Date().addingTimeInterval(request.readinessTimeout)

        while Date() < deadline {
            if !process.isRunning {
                throw CoreProcessError.unexpectedExit(capturedOutput)
            }
            if let version = try? await api.version() {
                return version
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CoreProcessError.readinessTimeout(capturedOutput)
    }
}

public struct CoreResourceSample: Equatable, Sendable {
    public var cpuTimeNanoseconds: UInt64
    public var memoryBytes: UInt64
    public var timestamp: Date

    public init(cpuTimeNanoseconds: UInt64, memoryBytes: UInt64, timestamp: Date) {
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryBytes = memoryBytes
        self.timestamp = timestamp
    }
}

public struct CoreResourceMonitor: Sendable {
    public init() {}

    public func snapshot(
        pid: Int32,
        previous: CoreResourceSample? = nil,
        timestamp: Date = Date()
    ) -> (snapshot: CoreResourceSnapshot, sample: CoreResourceSample)? {
        guard let current = sample(pid: pid, timestamp: timestamp) else {
            return nil
        }

        return (
            CoreResourceSnapshot(
                memoryBytes: Int(min(current.memoryBytes, UInt64(Int.max))),
                cpuPercent: previous.flatMap { Self.cpuPercent(previous: $0, current: current) },
                timestamp: current.timestamp
            ),
            current
        )
    }

    public func sample(pid: Int32, timestamp: Date = Date()) -> CoreResourceSample? {
        if let sample = taskInfoSample(pid: pid, timestamp: timestamp) {
            return sample
        }
        // TUN mode runs the core setuid-root, and proc_pidinfo against another user's
        // process fails with EPERM for an unprivileged caller — fall back to `ps`, which
        // reports basic accounting for any pid.
        return psSample(pid: pid, timestamp: timestamp)
    }

    private func taskInfoSample(pid: Int32, timestamp: Date) -> CoreResourceSample? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                Int32(MemoryLayout<proc_taskinfo>.stride)
            )
        }
        guard result == Int32(MemoryLayout<proc_taskinfo>.stride) else {
            return nil
        }

        return CoreResourceSample(
            cpuTimeNanoseconds: info.pti_total_user + info.pti_total_system,
            memoryBytes: info.pti_resident_size,
            timestamp: timestamp
        )
    }

    private func psSample(pid: Int32, timestamp: Date) -> CoreResourceSample? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=,cputime=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else {
            return nil
        }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let rssKilobytes = UInt64(fields[0]),
              let cpuNanoseconds = Self.nanoseconds(fromCPUTime: String(fields[1])) else {
            return nil
        }

        return CoreResourceSample(
            cpuTimeNanoseconds: cpuNanoseconds,
            memoryBytes: rssKilobytes * 1024,
            timestamp: timestamp
        )
    }

    /// Parses ps's cputime format `[[dd-]hh:]mm:ss.cc` (e.g. "7:21.06", "1:02:03.04",
    /// "2-03:04:05.06") into nanoseconds.
    public static func nanoseconds(fromCPUTime value: String) -> UInt64? {
        var remainder = Substring(value)
        var days: UInt64 = 0
        if let dashIndex = remainder.firstIndex(of: "-") {
            guard let parsed = UInt64(remainder[..<dashIndex]) else {
                return nil
            }
            days = parsed
            remainder = remainder[remainder.index(after: dashIndex)...]
        }

        let parts = remainder.split(separator: ":")
        guard (1...3).contains(parts.count), let seconds = Double(parts[parts.count - 1]) else {
            return nil
        }
        var totalSeconds = seconds
        var unit: Double = 60
        for part in parts.dropLast().reversed() {
            guard let component = Double(part) else {
                return nil
            }
            totalSeconds += component * unit
            unit *= 60
        }
        totalSeconds += Double(days) * 86_400

        guard totalSeconds.isFinite, totalSeconds >= 0 else {
            return nil
        }
        return UInt64(totalSeconds * 1_000_000_000)
    }

    public static func cpuPercent(previous: CoreResourceSample, current: CoreResourceSample) -> Double? {
        guard current.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds else {
            return nil
        }

        let wallNanoseconds = current.timestamp.timeIntervalSince(previous.timestamp) * 1_000_000_000
        guard wallNanoseconds > 0 else {
            return nil
        }

        let cpuNanoseconds = Double(current.cpuTimeNanoseconds - previous.cpuTimeNanoseconds)
        return max(0, min(cpuNanoseconds / wallNanoseconds * 100, 999))
    }
}
