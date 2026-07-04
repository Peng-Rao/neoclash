import NeoClashCore
import XCTest

final class UnlockTestServiceTests: XCTestCase {
    func testNetflixParsing() {
        let italy = UnlockTestService.parseNetflix(
            statusCode: 200,
            finalURL: URL(string: "https://www.netflix.com/it/title/81280792")
        )
        XCTAssertEqual(italy.0, .unlocked)
        XCTAssertEqual(italy.1, "IT")

        let us = UnlockTestService.parseNetflix(
            statusCode: 200,
            finalURL: URL(string: "https://www.netflix.com/title/81280792")
        )
        XCTAssertEqual(us.1, "US")

        XCTAssertEqual(UnlockTestService.parseNetflix(statusCode: 404, finalURL: nil).0, .locked)
        XCTAssertEqual(UnlockTestService.parseNetflix(statusCode: 500, finalURL: nil).0, .failed)
    }

    func testDisneyParsing() {
        let italy = UnlockTestService.parseDisney(finalURL: URL(string: "https://www.disneyplus.com/it-it/"))
        XCTAssertEqual(italy.0, .unlocked)
        XCTAssertEqual(italy.1, "IT")

        let blocked = UnlockTestService.parseDisney(finalURL: URL(string: "https://preview.disneyplus.com/unavailable"))
        XCTAssertEqual(blocked.0, .locked)
    }

    func testTraceValueParsing() {
        let trace = "fl=123\nip=1.2.3.4\nloc=IT\ncolo=MXP\n"
        XCTAssertEqual(UnlockTestService.traceValue(trace, key: "loc"), "IT")
        XCTAssertNil(UnlockTestService.traceValue(trace, key: "missing"))
    }

    func testChatGPTParsing() {
        XCTAssertEqual(UnlockTestService.parseChatGPTWeb(complianceBody: "{}", region: "IT").0, .unlocked)
        XCTAssertEqual(
            UnlockTestService.parseChatGPTWeb(complianceBody: #"{"error":"unsupported_country"}"#, region: nil).0,
            .locked
        )
        XCTAssertEqual(UnlockTestService.parseChatGPTiOS(body: "Request is not allowed. Please try again later."), .unlocked)
        XCTAssertEqual(UnlockTestService.parseChatGPTiOS(body: "You may be connected to a disallowed ISP."), .locked)
    }

    func testYouTubePremiumParsing() {
        let italy = UnlockTestService.parseYouTubePremium(body: #"..."countryCode":"IT"..."#)
        XCTAssertEqual(italy.0, .unlocked)
        XCTAssertEqual(italy.1, "IT")

        let blocked = UnlockTestService.parseYouTubePremium(body: "Premium is not available in your country")
        XCTAssertEqual(blocked.0, .locked)
    }

    func testSpotifyParsing() {
        let launched = #"{"status":311,"country":"IT","is_country_launched":true}"#
        let italy = UnlockTestService.parseSpotify(body: launched)
        XCTAssertEqual(italy.0, .unlocked)
        XCTAssertEqual(italy.1, "IT")

        XCTAssertEqual(UnlockTestService.parseSpotify(body: #"{"status":320}"#).0, .locked)
        XCTAssertEqual(UnlockTestService.parseSpotify(body: "not json").0, .failed)
    }

    func testBilibiliParsing() {
        XCTAssertEqual(UnlockTestService.parseBilibili(body: #"{"code":0,"message":"success"}"#), .unlocked)
        XCTAssertEqual(UnlockTestService.parseBilibili(body: #"{"code":-10403,"message":"抱歉您所在地区不可观看！"}"#), .locked)
        XCTAssertEqual(UnlockTestService.parseBilibili(body: "<html>"), .failed)
    }

    func testPrimeVideoAndTikTokParsing() {
        let prime = UnlockTestService.parsePrimeVideo(body: #""currentTerritory":"IT""#)
        XCTAssertEqual(prime.0, .unlocked)
        XCTAssertEqual(prime.1, "IT")

        let tikTok = UnlockTestService.parseTikTok(body: #""region":"IT","appType":"m""#)
        XCTAssertEqual(tikTok.0, .unlocked)
        XCTAssertEqual(tikTok.1, "IT")
    }

    func testFlagEmoji() {
        XCTAssertEqual(UnlockTestService.flagEmoji(forRegion: "IT"), "🇮🇹")
        XCTAssertEqual(UnlockTestService.flagEmoji(forRegion: "us"), "🇺🇸")
        // Gemini reports ISO alpha-3; the first two letters match alpha-2 for these regions.
        XCTAssertEqual(UnlockTestService.flagEmoji(forRegion: "ITA"), "🇮🇹")
        XCTAssertNil(UnlockTestService.flagEmoji(forRegion: nil))
        XCTAssertNil(UnlockTestService.flagEmoji(forRegion: "1"))
    }
}
