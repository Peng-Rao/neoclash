@testable import NeoClashCore
import Foundation
import XCTest

final class SubscriptionServiceTests: XCTestCase {
    func testServiceBoundaryRejectsInsecureSubscriptionURL() async throws {
        let fixture = try SubscriptionFixture()
        defer { fixture.cleanup() }

        let profileStore = ProfileStore(rootDirectory: fixture.root)
        let service = SubscriptionService(
            profileStore: profileStore,
            secretStore: InMemorySecretStore(),
            session: Self.stubSession()
        )

        do {
            _ = try await service.addSubscription(
                name: "Insecure",
                url: URL(string: "http://example.com/subscription")!
            )
            XCTFail("Expected HTTP to be rejected")
        } catch let error as SubscriptionError {
            XCTAssertEqual(error, .httpsRequired)
        }
        let profiles = await profileStore.allProfiles()
        XCTAssertEqual(profiles, [])
    }

    func testUpdateRejectsLegacyStoredHTTPSubscriptionURL() async throws {
        let fixture = try SubscriptionFixture()
        defer { fixture.cleanup() }

        let profileStore = ProfileStore(rootDirectory: fixture.root)
        let profile = try await profileStore.addRemoteProfile(
            name: "Legacy",
            yamlData: Data("proxies: []\n".utf8),
            subscriptionURL: URL(string: "https://example.com/unused")!
        )
        let secrets = InMemorySecretStore()
        secrets.save(
            "http://example.com/legacy",
            service: SubscriptionService.keychainService,
            account: profile.id.uuidString
        )
        let service = SubscriptionService(
            profileStore: profileStore,
            secretStore: secrets,
            session: Self.stubSession()
        )

        do {
            _ = try await service.update(profile: profile)
            XCTFail("Expected a stored HTTP URL to be rejected")
        } catch let error as SubscriptionError {
            XCTAssertEqual(error, .httpsRequired)
        }
    }

    func testRejectsDowngradedFinalResponseURL() async throws {
        let fixture = try SubscriptionFixture()
        defer { fixture.cleanup() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DowngradedSubscriptionURLProtocolStub.self]
        let service = SubscriptionService(
            profileStore: ProfileStore(rootDirectory: fixture.root),
            secretStore: InMemorySecretStore(),
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await service.addSubscription(
                name: "Downgraded",
                url: URL(string: "https://example.com/subscription")!
            )
            XCTFail("Expected a downgraded response URL to be rejected")
        } catch let error as SubscriptionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRedirectDelegateRefusesHTTPBeforeFollowUp() {
        let delegate = HTTPSOnlyRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/source")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/source")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let capture = RedirectRequestCapture()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://example.com/plaintext")!)
        ) { request in
            capture.record(request)
        }

        XCTAssertTrue(capture.wasCalled)
        XCTAssertNil(capture.request)
        session.invalidateAndCancel()
    }

    func testAddRollsBackProfileWhenSecretPersistenceFails() async throws {
        let fixture = try SubscriptionFixture()
        defer { fixture.cleanup() }

        let profileStore = ProfileStore(rootDirectory: fixture.root)
        let service = SubscriptionService(
            profileStore: profileStore,
            secretStore: FailingSecretStore(),
            session: Self.stubSession()
        )

        do {
            _ = try await service.addSubscription(
                name: "Example",
                url: URL(string: "https://example.com/subscription")!
            )
            XCTFail("Expected secret persistence to fail")
        } catch let error as SubscriptionTestError {
            XCTAssertEqual(error, .secretWrite)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let profiles = await profileStore.allProfiles()
        XCTAssertEqual(profiles, [])
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(entries.contains { UUID(uuidString: $0) != nil })
    }

    func testAddReportsOperationAndRollbackErrorsWhenProfileRollbackFails() async throws {
        let fixture = try SubscriptionFixture()
        defer { fixture.cleanup() }

        let writer = FailSecondMetadataWrite()
        let profileStore = ProfileStore(
            rootDirectory: fixture.root,
            atomicWrite: { data, url in try writer.write(data, to: url) }
        )
        let service = SubscriptionService(
            profileStore: profileStore,
            secretStore: FailingSecretStore(),
            session: Self.stubSession()
        )

        do {
            _ = try await service.addSubscription(
                name: "Example",
                url: URL(string: "https://example.com/subscription")!
            )
            XCTFail("Expected the transaction and its rollback to fail")
        } catch let error as SubscriptionError {
            XCTAssertEqual(
                error,
                .transactionRollbackFailed(
                    operation: SubscriptionTestError.secretWrite.localizedDescription,
                    rollback: SubscriptionTestError.metadataWrite.localizedDescription
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let profiles = await profileStore.allProfiles()
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.localFileURL.path))
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private enum SubscriptionTestError: Error, Equatable, LocalizedError {
    case secretWrite
    case metadataWrite

    var errorDescription: String? {
        switch self {
        case .secretWrite:
            "Secret write failed."
        case .metadataWrite:
            "Metadata write failed."
        }
    }
}

private struct FailingSecretStore: SecretStore {
    func save(_: String, service _: String, account _: String) throws {
        throw SubscriptionTestError.secretWrite
    }

    func load(service _: String, account _: String) throws -> String {
        throw SecretStoreError.notFound
    }

    func delete(service _: String, account _: String) throws {}
}

private final class FailSecondMetadataWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var metadataWriteCount = 0

    func write(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "profiles.json" {
            let shouldFail = lock.withLock {
                metadataWriteCount += 1
                return metadataWriteCount == 2
            }
            if shouldFail {
                throw SubscriptionTestError.metadataWrite
            }
        }
        try AtomicFileWriter.write(data, to: url)
    }
}

private final class SubscriptionURLProtocolStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "text/yaml"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("proxies: []\nrules: []\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DowngradedSubscriptionURLProtocolStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let downgradedURL = URL(string: "http://example.com/subscription")!
        let response = HTTPURLResponse(
            url: downgradedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/yaml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("proxies: []\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RedirectRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?
    private var called = false

    var request: URLRequest? { lock.withLock { capturedRequest } }
    var wasCalled: Bool { lock.withLock { called } }

    func record(_ request: URLRequest?) {
        lock.withLock {
            called = true
            capturedRequest = request
        }
    }
}

private struct SubscriptionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeoClashSubscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
