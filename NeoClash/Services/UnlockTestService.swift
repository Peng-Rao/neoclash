import Foundation

/// Probes which region-locked services the current proxy exit unlocks — the same checks
/// Clash Verge ships (RegionRestrictionCheck-style HTTP probes). Every request is forced
/// through the local mixed port so the verdict reflects the proxy, not the direct link.
/// Response parsing lives in pure static functions so each service's detection logic is
/// unit-testable without the network.
public struct UnlockTestService: Sendable {
    public enum Service: String, CaseIterable, Identifiable, Sendable {
        case bahamut = "Bahamut Anime"
        case chatGPTiOS = "ChatGPT iOS"
        case chatGPTWeb = "ChatGPT Web"
        case claude = "Claude"
        case disneyPlus = "Disney+"
        case gemini = "Gemini"
        case netflix = "Netflix"
        case primeVideo = "Prime Video"
        case spotify = "Spotify"
        case tikTok = "TikTok"
        case youtubePremium = "YouTube Premium"
        case bilibiliMainland = "哔哩哔哩大陆"
        case bilibiliHKMOTW = "哔哩哔哩港澳台"

        public var id: String { rawValue }
        public var displayName: String { rawValue }
    }

    public enum Status: Equatable, Sendable {
        case unlocked
        case locked
        case failed
    }

    public struct Result: Equatable, Sendable {
        public var status: Status
        public var region: String?
        public var testedAt: Date

        public init(status: Status, region: String? = nil, testedAt: Date = Date()) {
            self.status = status
            self.region = region
            self.testedAt = testedAt
        }
    }

    private let session: URLSession

    /// Pass the core's mixed port to probe through the proxy; nil probes directly.
    public init(proxyPort: Int?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        if let proxyPort {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: proxyPort
            ]
        }
        session = URLSession(configuration: configuration)
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    public func test(_ service: Service) async -> Result {
        do {
            let (status, region) = try await probe(service)
            return Result(status: status, region: region)
        } catch {
            return Result(status: .failed)
        }
    }

    // MARK: - Probes (network I/O per service)

    private func probe(_ service: Service) async throws -> (Status, String?) {
        switch service {
        case .netflix:
            // A licensed (non-original) title: only fully unlocked regions return 200.
            let response = try await fetch("https://www.netflix.com/title/81280792")
            return Self.parseNetflix(statusCode: response.http.statusCode, finalURL: response.http.url)

        case .disneyPlus:
            let response = try await fetch("https://www.disneyplus.com/")
            return Self.parseDisney(finalURL: response.http.url)

        case .chatGPTWeb:
            let trace = try await fetch("https://chat.openai.com/cdn-cgi/trace")
            let region = Self.traceValue(trace.body, key: "loc")
            let compliance = try await fetch(
                "https://api.openai.com/compliance/cookie_requirements",
                headers: ["Authorization": "Bearer null", "Content-Type": "application/json"]
            )
            return Self.parseChatGPTWeb(complianceBody: compliance.body, region: region)

        case .chatGPTiOS:
            let response = try await fetch("https://ios.chat.openai.com/")
            let status = Self.parseChatGPTiOS(body: response.body)
            let region = status == .unlocked
                ? Self.traceValue((try? await fetch("https://chat.openai.com/cdn-cgi/trace"))?.body ?? "", key: "loc")
                : nil
            return (status, region)

        case .claude:
            let response = try await fetch("https://claude.ai/")
            let blocked = Self.parseClaudeBlocked(finalURL: response.http.url, body: response.body)
            guard !blocked else {
                return (.locked, nil)
            }
            let region = Self.traceValue((try? await fetch("https://claude.ai/cdn-cgi/trace"))?.body ?? "", key: "loc")
            return (.unlocked, region)

        case .gemini:
            let response = try await fetch("https://gemini.google.com/")
            return Self.parseGemini(body: response.body)

        case .youtubePremium:
            // The SOCS cookie skips the EU consent interstitial that hides the real page.
            let response = try await fetch("https://www.youtube.com/premium", headers: ["Cookie": "SOCS=CAI"])
            return Self.parseYouTubePremium(body: response.body)

        case .primeVideo:
            let response = try await fetch("https://www.primevideo.com/")
            return Self.parsePrimeVideo(body: response.body)

        case .spotify:
            let response = try await fetch(
                "https://spclient.wg.spotify.com/signup/public/v1/account?birth_day=11&birth_month=11&birth_year=2000"
                    + "&collect_personal_info=undefined&creation_flow=&creation_point=client_mobile&displayname=Test"
                    + "&gender=male&iagree=1&key=a1e486e2729f46d6bb368d6b2bcda326&platform=www&referrer=&send-email=0"
                    + "&thirdpartyemail=0&identifier_token=AgE6YTvEzkReHNfJpO114514"
            )
            return Self.parseSpotify(body: response.body)

        case .tikTok:
            let response = try await fetch("https://www.tiktok.com/explore")
            return Self.parseTikTok(body: response.body)

        case .bilibiliMainland:
            // A mainland-only episode: code 0 means playable from this exit.
            let response = try await fetch(
                "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247"
                    + "&fourk=1&fnver=0&fnval=16"
            )
            let status = Self.parseBilibili(body: response.body)
            return (status, status == .unlocked ? "CN" : nil)

        case .bilibiliHKMOTW:
            // A HK/MO/TW-only episode.
            let response = try await fetch(
                "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json"
                    + "&ep_id=183799&fourk=1&fnver=0&fnval=16"
            )
            return (Self.parseBilibili(body: response.body), nil)

        case .bahamut:
            let response = try await fetch("https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=14667")
            let unlocked = response.body.contains("animeSn")
            return (unlocked ? .unlocked : .locked, unlocked ? "TW" : nil)
        }
    }

    private func fetch(_ urlString: String, headers: [String: String] = [:]) async throws -> (body: String, http: HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (String(data: data, encoding: .utf8) ?? "", http)
    }

    // MARK: - Parsers (pure, testable)

    public static func parseNetflix(statusCode: Int, finalURL: URL?) -> (Status, String?) {
        switch statusCode {
        case 200:
            // Unlocked regions redirect the title to a locale path ("/it/title/..."); the US has none.
            let first = finalURL?.pathComponents.dropFirst().first ?? "title"
            let region = first == "title" ? "US" : String(first.prefix(2)).uppercased()
            return (.unlocked, region)
        case 403, 404:
            return (.locked, nil)
        default:
            return (.failed, nil)
        }
    }

    public static func parseDisney(finalURL: URL?) -> (Status, String?) {
        let urlString = finalURL?.absoluteString.lowercased() ?? ""
        if urlString.contains("preview.disneyplus.com") || urlString.contains("unavailable") || urlString.contains("unsupported") {
            return (.locked, nil)
        }
        // Available regions land on a "/it-it/"-style locale path.
        if let first = finalURL?.pathComponents.dropFirst().first, first.count == 5, first.contains("-") {
            return (.unlocked, String(first.suffix(2)).uppercased())
        }
        return (.unlocked, nil)
    }

    public static func parseChatGPTWeb(complianceBody: String, region: String?) -> (Status, String?) {
        let blocked = complianceBody.lowercased().contains("unsupported_country")
        return (blocked ? .locked : .unlocked, region)
    }

    public static func parseChatGPTiOS(body: String) -> Status {
        let lowered = body.lowercased()
        if lowered.contains("disallowed isp") || lowered.contains("vpn") {
            return .locked
        }
        if lowered.contains("request is not allowed") {
            return .unlocked
        }
        return .failed
    }

    public static func parseClaudeBlocked(finalURL: URL?, body: String) -> Bool {
        let urlString = finalURL?.absoluteString.lowercased() ?? ""
        return urlString.contains("app-unavailable") || body.lowercased().contains("unavailable-in-region")
    }

    public static func parseGemini(body: String) -> (Status, String?) {
        let unlocked = body.contains("45631641,null,true")
        let region = firstMatch(in: body, pattern: #",2,1,200,"([A-Z]{3})""#)
        return (unlocked ? .unlocked : .locked, region)
    }

    public static func parseYouTubePremium(body: String) -> (Status, String?) {
        if body.contains("Premium is not available in your country") {
            return (.locked, nil)
        }
        if let region = firstMatch(in: body, pattern: #""countryCode":"([A-Z]{2})""#) {
            return (.unlocked, region)
        }
        // The US page omits countryCode entirely.
        if body.contains("YouTube Premium") || body.contains("purchaseButtonOverride") {
            return (.unlocked, "US")
        }
        return (.failed, nil)
    }

    public static func parsePrimeVideo(body: String) -> (Status, String?) {
        if let region = firstMatch(in: body, pattern: #""currentTerritory":"([A-Z]{2})""#) {
            return (.unlocked, region)
        }
        if body.contains("isServiceRestricted") {
            return (.locked, nil)
        }
        return (.failed, nil)
    }

    public static func parseSpotify(body: String) -> (Status, String?) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int else {
            return (.failed, nil)
        }
        let country = json["country"] as? String
        let launched = json["is_country_launched"] as? Bool ?? false
        return (status == 311 && launched) ? (.unlocked, country) : (.locked, country)
    }

    public static func parseTikTok(body: String) -> (Status, String?) {
        if let region = firstMatch(in: body, pattern: #""region":"([A-Z]{2})""#) {
            return (.unlocked, region)
        }
        if body.lowercased().contains("access denied") {
            return (.locked, nil)
        }
        return (.failed, nil)
    }

    public static func parseBilibili(body: String) -> Status {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int else {
            return .failed
        }
        switch code {
        case 0:
            return .unlocked
        case -10403:
            return .locked
        default:
            return .failed
        }
    }

    // MARK: - Helpers

    /// Reads a `key=value` line from a Cloudflare `/cdn-cgi/trace` body.
    public static func traceValue(_ body: String, key: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == Substring(key) {
                return String(parts[1])
            }
        }
        return nil
    }

    public static func firstMatch(in body: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return String(body[captured])
    }

    /// "IT" → 🇮🇹. Three-letter codes fall back to their first two letters, which matches
    /// ISO alpha-2 for the regions these services report.
    public static func flagEmoji(forRegion code: String?) -> String? {
        guard let code, (2...3).contains(code.count) else {
            return nil
        }
        let letters = code.uppercased().prefix(2).unicodeScalars.compactMap { scalar -> String? in
            guard scalar.value >= 65, scalar.value <= 90,
                  let flagScalar = UnicodeScalar(0x1F1E6 + (scalar.value - 65)) else {
                return nil
            }
            return String(flagScalar)
        }
        return letters.count == 2 ? letters.joined() : nil
    }
}
