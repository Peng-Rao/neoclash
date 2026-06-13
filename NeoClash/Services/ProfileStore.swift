import Foundation
@preconcurrency import Yams

public enum ProfileStoreError: Error, Equatable, LocalizedError {
    case profileNotFound(UUID)
    case invalidProfileName
    case invalidYAML

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Profile not found: \(id.uuidString)."
        case .invalidProfileName:
            "Profile name cannot be empty."
        case .invalidYAML:
            "Profile YAML is invalid."
        }
    }
}

public actor ProfileStore {
    private let rootDirectory: URL
    private let metadataURL: URL
    private var profiles: [ProxyProfile] = []

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.metadataURL = rootDirectory.appendingPathComponent("profiles.json")
    }

    public func load() throws -> [ProxyProfile] {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            profiles = []
            return profiles
        }
        let data = try Data(contentsOf: metadataURL)
        profiles = try JSONDecoder.profileDecoder.decode([ProxyProfile].self, from: data)
        return profiles
    }

    public func allProfiles() -> [ProxyProfile] {
        profiles.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func importLocalYAML(name: String, yamlData: Data) throws -> ProxyProfile {
        try validate(name: name)
        try validateYAML(yamlData)

        let id = UUID()
        let profile = ProxyProfile(
            id: id,
            name: name,
            kind: .localYAML,
            localFileURL: profileFileURL(id: id)
        )
        try writeProfile(profile, yamlData: yamlData, replacingExisting: false)
        profiles.append(profile)
        try save()
        return profile
    }

    @discardableResult
    public func addRemoteProfile(name: String, yamlData: Data, subscriptionURL _: URL) throws -> ProxyProfile {
        try validate(name: name)
        try validateYAML(yamlData)

        let id = UUID()
        let profile = ProxyProfile(
            id: id,
            name: name,
            kind: .remoteSubscription,
            localFileURL: profileFileURL(id: id),
            lastUpdatedAt: Date()
        )
        try writeProfile(profile, yamlData: yamlData, replacingExisting: false)
        profiles.append(profile)
        try save()
        return profile
    }

    @discardableResult
    public func replaceProfileYAML(profileID: UUID, yamlData: Data, updatedAt: Date = Date()) throws -> ProxyProfile {
        try validateYAML(yamlData)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        var profile = profiles[index]
        try writeProfile(profile, yamlData: yamlData, replacingExisting: true)
        profile.lastUpdatedAt = updatedAt
        profiles[index] = profile
        try save()
        return profile
    }

    public func rename(profileID: UUID, to name: String) throws {
        try validate(name: name)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        profiles[index].name = name
        try save()
    }

    public func delete(profileID: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        let profile = profiles.remove(at: index)
        try? FileManager.default.removeItem(at: profile.localFileURL.deletingLastPathComponent())
        try save()
    }

    public func yaml(for profile: ProxyProfile) throws -> String {
        try String(contentsOf: profile.localFileURL, encoding: .utf8)
    }

    private func writeProfile(_ profile: ProxyProfile, yamlData: Data, replacingExisting: Bool) throws {
        let directory = profile.localFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if replacingExisting {
            let backupURL = directory.appendingPathComponent("last-known-good.yaml")
            if FileManager.default.fileExists(atPath: profile.localFileURL.path) {
                try? FileManager.default.copyItemReplacingExisting(from: profile.localFileURL, to: backupURL)
            }
        }
        try AtomicFileWriter.write(yamlData, to: profile.localFileURL)
    }

    private func profileFileURL(id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("original.yaml")
    }

    private func save() throws {
        let data = try JSONEncoder.profileEncoder.encode(profiles)
        try AtomicFileWriter.write(data, to: metadataURL)
    }

    private func validate(name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileStoreError.invalidProfileName
        }
    }

    private func validateYAML(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), (try? Yams.compose(yaml: text)) != nil else {
            throw ProfileStoreError.invalidYAML
        }
    }
}

private extension JSONEncoder {
    static var profileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var profileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension FileManager {
    func copyItemReplacingExisting(from source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}
