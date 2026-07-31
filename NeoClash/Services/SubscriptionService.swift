import Foundation
@preconcurrency import Yams

public enum SubscriptionError: Error, Equatable, LocalizedError {
    case missingURL(UUID)
    case responseTooLarge(Int)
    case invalidResponse
    case invalidYAML
    case httpsRequired
    case transactionRollbackFailed(operation: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .missingURL(let id):
            "No subscription URL is stored for profile \(id.uuidString)."
        case .responseTooLarge(let bytes):
            "Subscription response is too large: \(bytes) bytes."
        case .invalidResponse:
            "Subscription server returned an invalid response."
        case .invalidYAML:
            "Subscription response is not valid YAML."
        case .httpsRequired:
            "Subscription URLs must use HTTPS."
        case .transactionRollbackFailed(let operation, let rollback):
            "Subscription creation failed: \(operation) Profile rollback also failed: \(rollback)"
        }
    }
}

final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.isEmpty == false else {
            // Reject the redirect before URLSession can transmit a request (or URL-embedded
            // subscription credential) over cleartext HTTP.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public actor SubscriptionService {
    public static let keychainService = "com.pengrao.NeoClash.subscription"

    private let profileStore: ProfileStore
    private let secretStore: SecretStore
    private let redirectDelegate: HTTPSOnlyRedirectDelegate
    private let session: URLSession
    private let maxResponseBytes: Int

    public init(
        profileStore: ProfileStore,
        secretStore: SecretStore = KeychainStore(),
        timeout: TimeInterval = 20,
        maxResponseBytes: Int = 5 * 1024 * 1024,
        session: URLSession? = nil
    ) {
        self.profileStore = profileStore
        self.secretStore = secretStore
        self.maxResponseBytes = maxResponseBytes

        let configuration: URLSessionConfiguration
        if let session {
            // Recreate injected test/custom sessions from their configuration so the HTTPS-only
            // redirect policy cannot be bypassed by a caller-supplied session delegate.
            configuration = session.configuration
        } else {
            configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
        }
        let redirectDelegate = HTTPSOnlyRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    @discardableResult
    public func addSubscription(name: String, url: URL) async throws -> ProxyProfile {
        let data = try await fetchSubscription(from: url)
        let profile = try await profileStore.addRemoteProfile(name: name, yamlData: data, subscriptionURL: url)
        do {
            try secretStore.save(url.absoluteString, service: Self.keychainService, account: profile.id.uuidString)
        } catch let operationError {
            do {
                try await profileStore.delete(profileID: profile.id)
            } catch let rollbackError {
                throw SubscriptionError.transactionRollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
        return profile
    }

    @discardableResult
    public func update(profile: ProxyProfile) async throws -> ProxyProfile {
        let urlString: String
        do {
            urlString = try secretStore.load(service: Self.keychainService, account: profile.id.uuidString)
        } catch SecretStoreError.notFound {
            throw SubscriptionError.missingURL(profile.id)
        }
        guard let url = URL(string: urlString) else {
            throw SubscriptionError.invalidResponse
        }

        let data = try await fetchSubscription(from: url)
        return try await profileStore.replaceProfileYAML(profileID: profile.id, yamlData: data)
    }

    public func removeStoredURL(profileID: UUID) throws {
        try secretStore.delete(service: Self.keychainService, account: profileID.uuidString)
    }

    public func redactedURL(for profileID: UUID) -> String? {
        guard let value = try? secretStore.load(service: Self.keychainService, account: profileID.uuidString) else {
            return nil
        }
        return Redactor.redact(value)
    }

    private func fetchSubscription(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw SubscriptionError.httpsRequired
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest
        request.setValue("NeoClash/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url?.scheme?.lowercased() == "https",
              (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionError.invalidResponse
        }
        guard data.count <= maxResponseBytes else {
            throw SubscriptionError.responseTooLarge(data.count)
        }
        guard let yaml = String(data: data, encoding: .utf8), (try? Yams.compose(yaml: yaml)) != nil else {
            throw SubscriptionError.invalidYAML
        }
        return data
    }
}
