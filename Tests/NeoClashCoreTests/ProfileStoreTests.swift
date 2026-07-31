@testable import NeoClashCore
import Foundation
import XCTest

final class ProfileStoreTests: XCTestCase {
    func testLoadCanonicalizesPersistedPathAndDeleteNeverTouchesOutsideDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let id = UUID()
        let canonicalDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalDirectory, withIntermediateDirectories: true)
        try Data("proxies: []\n".utf8).write(to: canonicalDirectory.appendingPathComponent("original.yaml"))

        let outsideDirectory = fixture.outside.appendingPathComponent("must-survive", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sentinel = outsideDirectory.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)

        let poisoned = ProxyProfile(
            id: id,
            name: "Poisoned metadata",
            kind: .localYAML,
            localFileURL: outsideDirectory.appendingPathComponent("original.yaml")
        )
        try writeMetadata([poisoned], to: fixture.root)

        let store = ProfileStore(rootDirectory: fixture.root)
        let loaded = try await store.load()
        let profile = try XCTUnwrap(loaded.first)
        XCTAssertEqual(
            profile.localFileURL,
            canonicalDirectory.appendingPathComponent("original.yaml").resolvingSymlinksInPath().standardizedFileURL
        )

        try await store.delete(profileID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalDirectory.path))
    }

    func testLoadRejectsUUIDDirectorySymlinkThatEscapesRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let id = UUID()
        let outsideProfileDirectory = fixture.outside.appendingPathComponent("escaped-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideProfileDirectory, withIntermediateDirectories: true)
        try Data("proxies: []\n".utf8).write(to: outsideProfileDirectory.appendingPathComponent("original.yaml"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(id.uuidString, isDirectory: true),
            withDestinationURL: outsideProfileDirectory
        )

        let profile = ProxyProfile(
            id: id,
            name: "Escaped",
            kind: .localYAML,
            localFileURL: fixture.root.appendingPathComponent(id.uuidString).appendingPathComponent("original.yaml")
        )
        try writeMetadata([profile], to: fixture.root)

        let store = ProfileStore(rootDirectory: fixture.root)
        do {
            _ = try await store.load()
            XCTFail("Expected the escaping symlink to be rejected")
        } catch let error as ProfileStoreError {
            guard case .unsafeProfilePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLoadRejectsUUIDDirectorySymlinkThatAliasesAnotherManagedDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let id = UUID()
        let aliasedDirectory = fixture.root.appendingPathComponent("aliased-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasedDirectory, withIntermediateDirectories: true)
        try Data("proxies: []\n".utf8).write(to: aliasedDirectory.appendingPathComponent("original.yaml"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(id.uuidString, isDirectory: true),
            withDestinationURL: aliasedDirectory
        )

        let profile = ProxyProfile(
            id: id,
            name: "Aliased",
            kind: .localYAML,
            localFileURL: fixture.root.appendingPathComponent(id.uuidString).appendingPathComponent("original.yaml")
        )
        try writeMetadata([profile], to: fixture.root)

        do {
            _ = try await ProfileStore(rootDirectory: fixture.root).load()
            XCTFail("Expected an internal directory symlink to be rejected")
        } catch let error as ProfileStoreError {
            guard case .unsafeProfilePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testReplaceRejectsBackupSymlinkToMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let store = ProfileStore(rootDirectory: fixture.root)
        let original = Data("proxies: []\n".utf8)
        let profile = try await store.importLocalYAML(name: "Original", yamlData: original)
        let metadataURL = fixture.root.appendingPathComponent("profiles.json")
        let metadataBefore = try Data(contentsOf: metadataURL)
        let backupURL = profile.localFileURL.deletingLastPathComponent()
            .appendingPathComponent("last-known-good.yaml")
        try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: metadataURL)

        do {
            _ = try await store.replaceProfileYAML(
                profileID: profile.id,
                yamlData: Data("proxies: []\nrules: []\n".utf8)
            )
            XCTFail("Expected the backup symlink to be rejected")
        } catch let error as ProfileStoreError {
            guard case .unsafeProfilePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: profile.localFileURL), original)
    }

    func testLoadDropsMetadataWhoseCanonicalYAMLIsMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let id = UUID()
        let missing = ProxyProfile(
            id: id,
            name: "Missing",
            kind: .localYAML,
            localFileURL: URL(fileURLWithPath: "/tmp/untrusted/original.yaml")
        )
        try writeMetadata([missing], to: fixture.root)

        let store = ProfileStore(rootDirectory: fixture.root)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])

        let reloaded = try await ProfileStore(rootDirectory: fixture.root).load()
        XCTAssertEqual(reloaded, [])
    }

    func testImportRejectsScalarAndSequenceYAMLRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ProfileStore(rootDirectory: fixture.root)

        for yaml in ["just-a-scalar\n", "- one\n- two\n"] {
            do {
                _ = try await store.importLocalYAML(name: "Invalid", yamlData: Data(yaml.utf8))
                XCTFail("Expected a non-mapping YAML root to be rejected")
            } catch let error as ProfileStoreError {
                XCTAssertEqual(error, .invalidYAML)
            }
        }
        let profiles = await store.allProfiles()
        XCTAssertEqual(profiles, [])
    }

    func testMetadataWriteFailuresRollBackMemoryYAMLAndDeletedDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let writer = ControllableWriter()
        let store = ProfileStore(
            rootDirectory: fixture.root,
            atomicWrite: { data, url in try writer.write(data, to: url) }
        )

        let originalYAML = Data("proxies: []\nrules: []\n".utf8)
        let profile = try await store.importLocalYAML(name: "Original", yamlData: originalYAML)
        writer.failMetadataWrites = true

        await assertThrows {
            try await store.rename(profileID: profile.id, to: "Unexpected rename")
        }
        let profilesAfterRename = await store.allProfiles()
        XCTAssertEqual(profilesAfterRename.first?.name, "Original")

        await assertThrows {
            _ = try await store.replaceProfileYAML(
                profileID: profile.id,
                yamlData: Data("proxies: []\nrules:\n  - MATCH,DIRECT\n".utf8)
            )
        }
        let yamlAfterReplace = try await store.yaml(for: profile)
        XCTAssertEqual(yamlAfterReplace, String(decoding: originalYAML, as: UTF8.self))

        await assertThrows {
            try await store.delete(profileID: profile.id)
        }
        let profilesAfterDelete = await store.allProfiles()
        XCTAssertEqual(profilesAfterDelete.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.localFileURL.path))

        writer.failMetadataWrites = false
        let diskProfiles = try await ProfileStore(rootDirectory: fixture.root).load()
        XCTAssertEqual(diskProfiles.map(\.name), ["Original"])
        let diskStore = ProfileStore(rootDirectory: fixture.root)
        let diskYAML = try await diskStore.yaml(for: diskProfiles[0])
        XCTAssertEqual(diskYAML, String(decoding: originalYAML, as: UTF8.self))
    }

    func testFailedImportRemovesNewProfileDirectoryAndKeepsMemoryEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let writer = ControllableWriter()
        writer.failMetadataWrites = true
        let store = ProfileStore(
            rootDirectory: fixture.root,
            atomicWrite: { data, url in try writer.write(data, to: url) }
        )

        await assertThrows {
            _ = try await store.importLocalYAML(name: "Will fail", yamlData: Data("proxies: []\n".utf8))
        }
        let profiles = await store.allProfiles()
        XCTAssertEqual(profiles, [])

        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(entries.contains { UUID(uuidString: $0) != nil })
    }

    private func assertThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }

    private func writeMetadata(_ profiles: [ProxyProfile], to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: root.appendingPathComponent("profiles.json"))
    }
}

private final class ControllableWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailMetadataWrites = false

    var failMetadataWrites: Bool {
        get { lock.withLock { shouldFailMetadataWrites } }
        set { lock.withLock { shouldFailMetadataWrites = newValue } }
    }

    func write(_ data: Data, to url: URL) throws {
        if failMetadataWrites, url.lastPathComponent == "profiles.json" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try AtomicFileWriter.write(data, to: url)
    }
}

private struct Fixture {
    let root: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeoClashProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Profiles", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
