import Foundation
@preconcurrency import Yams

public enum ProfileStoreError: Error, Equatable, LocalizedError {
    case profileNotFound(UUID)
    case invalidProfileName
    case invalidYAML
    case unsafeProfilePath(URL)
    case transactionRollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Profile not found: \(id.uuidString)."
        case .invalidProfileName:
            "Profile name cannot be empty."
        case .invalidYAML:
            "Profile YAML must be a valid mapping."
        case .unsafeProfilePath(let url):
            "Profile path escapes the profile store: \(url.path)."
        case .transactionRollbackFailed(let message):
            "Profile transaction rollback failed: \(message)"
        }
    }
}

typealias ProfileStoreAtomicWrite = @Sendable (Data, URL) throws -> Void

public actor ProfileStore {
    private static let metadataFileName = "profiles.json"
    private static let originalFileName = "original.yaml"
    private static let backupFileName = "last-known-good.yaml"
    private static let tombstonesDirectoryName = ".delete-tombstones"

    private let rootDirectory: URL
    private let metadataURL: URL
    private let fileManager: FileManager
    private let atomicWrite: ProfileStoreAtomicWrite
    private var profiles: [ProxyProfile] = []
    private var isLoaded = false

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.metadataURL = rootDirectory.standardizedFileURL
            .appendingPathComponent(Self.metadataFileName)
        self.fileManager = .default
        self.atomicWrite = { data, destination in
            try AtomicFileWriter.write(data, to: destination)
        }
    }

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        atomicWrite: @escaping ProfileStoreAtomicWrite
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.metadataURL = rootDirectory.standardizedFileURL
            .appendingPathComponent(Self.metadataFileName)
        self.fileManager = fileManager
        self.atomicWrite = atomicWrite
    }

    public func load() throws -> [ProxyProfile] {
        try prepareRootDirectory()
        let safeMetadataURL = try validatedStoreURL(metadataURL)
        guard fileManager.fileExists(atPath: safeMetadataURL.path) else {
            try reconcileTombstones(metadataProfileIDs: [])
            profiles = []
            isLoaded = true
            return profiles
        }

        let data = try Data(contentsOf: safeMetadataURL)
        let decoded = try JSONDecoder.profileDecoder.decode([ProxyProfile].self, from: data)
        let decodedIDs = Set(decoded.map(\.id))
        try reconcileTombstones(metadataProfileIDs: decodedIDs)

        var seenIDs: Set<UUID> = []
        var reconciled: [ProxyProfile] = []
        var metadataChanged = false

        for storedProfile in decoded {
            guard seenIDs.insert(storedProfile.id).inserted else {
                metadataChanged = true
                continue
            }

            let canonicalURL = try profileFileURL(id: storedProfile.id)
            guard isRegularFile(at: canonicalURL) else {
                // Metadata without its YAML cannot produce a usable profile. Drop the stale
                // record now so callers never receive an entry that is guaranteed to fail.
                metadataChanged = true
                continue
            }

            var profile = storedProfile
            if profile.localFileURL.standardizedFileURL != canonicalURL {
                metadataChanged = true
            }
            profile.localFileURL = canonicalURL
            reconciled.append(profile)
        }

        if metadataChanged {
            try save(reconciled)
        }
        profiles = reconciled
        isLoaded = true
        return profiles
    }

    public func allProfiles() -> [ProxyProfile] {
        profiles.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func importLocalYAML(name: String, yamlData: Data) throws -> ProxyProfile {
        try loadIfNeeded()
        try validate(name: name)
        try validateYAML(yamlData)

        return try addProfile(name: name, kind: .localYAML, yamlData: yamlData, updatedAt: nil)
    }

    @discardableResult
    public func addRemoteProfile(name: String, yamlData: Data, subscriptionURL _: URL) throws -> ProxyProfile {
        try loadIfNeeded()
        try validate(name: name)
        try validateYAML(yamlData)

        return try addProfile(name: name, kind: .remoteSubscription, yamlData: yamlData, updatedAt: Date())
    }

    @discardableResult
    public func replaceProfileYAML(profileID: UUID, yamlData: Data, updatedAt: Date = Date()) throws -> ProxyProfile {
        try loadIfNeeded()
        try validateYAML(yamlData)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        let originalURL = try profileFileURL(id: profileID)
        let backupURL = try validatedStoreURL(
            originalURL.deletingLastPathComponent().appendingPathComponent(Self.backupFileName)
        )
        let previousYAML = try Data(contentsOf: originalURL)
        let previousBackup = try existingData(at: backupURL)

        // Do not silently discard an older last-known-good file. AtomicFileWriter leaves it
        // untouched if this replacement cannot be committed.
        try atomicWrite(previousYAML, backupURL)

        do {
            try atomicWrite(yamlData, originalURL)
            var nextProfiles = profiles
            nextProfiles[index].lastUpdatedAt = updatedAt
            nextProfiles[index].localFileURL = originalURL
            try save(nextProfiles)
            profiles = nextProfiles
            return nextProfiles[index]
        } catch {
            do {
                try atomicWrite(previousYAML, originalURL)
                try restore(previousData: previousBackup, at: backupURL)
            } catch let rollbackError {
                throw ProfileStoreError.transactionRollbackFailed(rollbackError.localizedDescription)
            }
            throw error
        }
    }

    public func rename(profileID: UUID, to name: String) throws {
        try loadIfNeeded()
        try validate(name: name)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        var nextProfiles = profiles
        nextProfiles[index].name = name
        nextProfiles[index].localFileURL = try profileFileURL(id: profileID)
        try save(nextProfiles)
        profiles = nextProfiles
    }

    public func delete(profileID: UUID) throws {
        try loadIfNeeded()
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        let directory = try profileDirectoryURL(id: profileID)
        let tombstone = try tombstoneURL(id: profileID, createParent: true)
        var movedToTombstone = false

        if fileManager.fileExists(atPath: tombstone.path) {
            // A loaded store normally reconciles this. Handle it here as well for callers that
            // encounter a tombstone created by an interrupted operation in the same process.
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: tombstone)
            } else {
                try fileManager.moveItem(at: tombstone, to: directory)
            }
        }

        if fileManager.fileExists(atPath: directory.path) {
            // Moving within the profile root is atomic and reversible. No profile bytes are
            // destroyed until the metadata removal has committed successfully.
            try fileManager.moveItem(at: directory, to: tombstone)
            movedToTombstone = true
        }

        var nextProfiles = profiles
        nextProfiles.remove(at: index)
        do {
            try save(nextProfiles)
        } catch {
            if movedToTombstone {
                do {
                    try fileManager.moveItem(at: tombstone, to: directory)
                } catch let rollbackError {
                    throw ProfileStoreError.transactionRollbackFailed(rollbackError.localizedDescription)
                }
            }
            throw error
        }

        profiles = nextProfiles
        if movedToTombstone {
            // Metadata is authoritative now. A crash or removal failure leaves a recognizable
            // tombstone that load() will clean rather than resurrecting a deleted profile.
            try? fileManager.removeItem(at: tombstone)
        }
    }

    public func yaml(for profile: ProxyProfile) throws -> String {
        try loadIfNeeded()
        guard profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileStoreError.profileNotFound(profile.id)
        }
        return try String(contentsOf: profileFileURL(id: profile.id), encoding: .utf8)
    }

    private func addProfile(
        name: String,
        kind: ProfileKind,
        yamlData: Data,
        updatedAt: Date?
    ) throws -> ProxyProfile {
        let id = UUID()
        let fileURL = try profileFileURL(id: id)
        let directory = fileURL.deletingLastPathComponent()
        let profile = ProxyProfile(
            id: id,
            name: name,
            kind: kind,
            localFileURL: fileURL,
            lastUpdatedAt: updatedAt
        )
        let nextProfiles = profiles + [profile]

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            _ = try validatedStoreURL(directory)
            try atomicWrite(yamlData, fileURL)
            try save(nextProfiles)
        } catch {
            do {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            } catch let rollbackError {
                throw ProfileStoreError.transactionRollbackFailed(rollbackError.localizedDescription)
            }
            throw error
        }

        profiles = nextProfiles
        return profile
    }

    private func loadIfNeeded() throws {
        if !isLoaded {
            _ = try load()
        }
    }

    private func prepareRootDirectory() throws {
        guard rootDirectory.isFileURL else {
            throw ProfileStoreError.unsafeProfilePath(rootDirectory)
        }
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        _ = try validatedStoreURL(rootDirectory)
    }

    private func profileDirectoryURL(id: UUID) throws -> URL {
        try validatedStoreURL(
            rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        )
    }

    private func profileFileURL(id: UUID) throws -> URL {
        try validatedStoreURL(
            profileDirectoryURL(id: id).appendingPathComponent(Self.originalFileName)
        )
    }

    private func tombstoneURL(id: UUID, createParent: Bool = false) throws -> URL {
        let parent = try validatedStoreURL(
            rootDirectory.appendingPathComponent(Self.tombstonesDirectoryName, isDirectory: true)
        )
        if createParent {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try validatedStoreURL(parent)
        }
        return try validatedStoreURL(parent.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    private func validatedStoreURL(_ candidate: URL) throws -> URL {
        guard candidate.isFileURL else {
            throw ProfileStoreError.unsafeProfilePath(candidate)
        }

        let lexicalRoot = rootDirectory.standardizedFileURL
        let lexicalCandidate = candidate.standardizedFileURL
        let lexicalRootComponents = lexicalRoot.pathComponents
        let lexicalCandidateComponents = lexicalCandidate.pathComponents
        guard lexicalCandidateComponents.starts(with: lexicalRootComponents) else {
            throw ProfileStoreError.unsafeProfilePath(candidate)
        }

        let resolvedRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let relativeComponents = lexicalCandidateComponents.dropFirst(lexicalRootComponents.count)
        let expectedCandidate = relativeComponents.reduce(resolvedRoot) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        let resolvedCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL

        // Managed paths must be direct descendants, not symlink aliases. Merely checking that the
        // resolved target remains somewhere under the store lets one profile alias another and
        // makes delete/backup operations mutate the wrong profile or metadata file.
        guard resolvedCandidate == expectedCandidate else {
            throw ProfileStoreError.unsafeProfilePath(candidate)
        }
        return expectedCandidate
    }

    private func reconcileTombstones(metadataProfileIDs: Set<UUID>) throws {
        for id in metadataProfileIDs {
            let directory = try profileDirectoryURL(id: id)
            let tombstone = try tombstoneURL(id: id)
            if !fileManager.fileExists(atPath: directory.path),
               fileManager.fileExists(atPath: tombstone.path) {
                try fileManager.moveItem(at: tombstone, to: directory)
            }
        }

        let tombstoneRoot = try validatedStoreURL(
            rootDirectory.appendingPathComponent(Self.tombstonesDirectoryName, isDirectory: true)
        )
        guard fileManager.fileExists(atPath: tombstoneRoot.path) else {
            return
        }

        for entry in try fileManager.contentsOfDirectory(
            at: tombstoneRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  !metadataProfileIDs.contains(id) else {
                continue
            }
            try fileManager.removeItem(at: try validatedStoreURL(entry))
        }
    }

    private func save(_ candidateProfiles: [ProxyProfile]) throws {
        let data = try JSONEncoder.profileEncoder.encode(candidateProfiles)
        try atomicWrite(data, try validatedStoreURL(metadataURL))
    }

    private func existingData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func restore(previousData: Data?, at url: URL) throws {
        if let previousData {
            try atomicWrite(previousData, url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func isRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func validate(name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileStoreError.invalidProfileName
        }
    }

    private func validateYAML(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              let object = try? Yams.load(yaml: text),
              object is [String: Any] else {
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
