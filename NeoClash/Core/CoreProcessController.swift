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

    public init(
        coreURL: URL,
        runtimeDirectory: URL,
        runtimeConfigURL: URL,
        manifest: CoreManifest? = nil,
        ports: RuntimePorts = RuntimePorts(),
        secret: String,
        readinessTimeout: TimeInterval = 10
    ) {
        self.coreURL = coreURL
        self.runtimeDirectory = runtimeDirectory
        self.runtimeConfigURL = runtimeConfigURL
        self.manifest = manifest
        self.ports = ports
        self.secret = secret
        self.readinessTimeout = readinessTimeout
    }
}

public struct CoreLaunchResult: Equatable, Sendable {
    public var version: String
    public var processIdentifier: Int32
}

public enum CoreProcessError: Error, Equatable, LocalizedError {
    case portUnavailable(Int)
    case processAlreadyRunning
    case readinessTimeout(String)
    case unexpectedExit(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let port):
            "Required port is unavailable: \(port)."
        case .processAlreadyRunning:
            "A core process is already running."
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
    private var output = RingBuffer<String>(capacity: 256)

    public init(validator: CoreBinaryValidator = CoreBinaryValidator(), portChecker: PortChecker = PortChecker()) {
        self.validator = validator
        self.portChecker = portChecker
    }

    public var capturedOutput: String {
        output.elements.joined(separator: "\n")
    }

    public func start(_ request: CoreStartRequest) async throws -> CoreLaunchResult {
        if process?.isRunning == true {
            throw CoreProcessError.processAlreadyRunning
        }

        try validator.validate(coreURL: request.coreURL, manifest: request.manifest)
        guard portChecker.isAvailable(host: request.ports.controllerHost, port: request.ports.controllerPort) else {
            throw CoreProcessError.portUnavailable(request.ports.controllerPort)
        }
        guard portChecker.isAvailable(host: "127.0.0.1", port: request.ports.mixedPort) else {
            throw CoreProcessError.portUnavailable(request.ports.mixedPort)
        }

        let launched = try launchProcess(request)
        process = launched

        do {
            let version = try await waitUntilReady(request: request, process: launched)
            return CoreLaunchResult(version: version.version, processIdentifier: launched.processIdentifier)
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        guard let process else {
            return
        }
        self.process = nil

        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
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

    private func capture(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
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

