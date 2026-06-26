import Foundation
import simd

/// Resolves proxy node / chain names (and the local machine) to approximate map coordinates.
/// All coordinates are `(longitude, latitude)`.
///
/// Matching order, most specific first:
///   1. Curated proxy-hub aliases (cities + countries, English / 中文 / ISO codes).
///   2. A flag emoji embedded in the name (🇸🇬 → SG).
///   3. Any English country name appearing as a whole word.
///   4. The session's egress country code, when known.
enum GeoLocator {
    struct Place {
        var lon: Double
        var lat: Double
        /// ASCII aliases are matched as whole tokens when ≤ 2 chars, else as substrings.
        /// CJK aliases are matched as substrings.
        var aliases: [String]
        var coordinate: SIMD2<Double> { .init(lon, lat) }
    }

    // Ordered so a city wins over the country that contains it.
    static let places: [Place] = [
        // East Asia
        .init(lon: 103.85, lat: 1.29, aliases: ["singapore", "sg", "新加坡", "狮城", "獅城"]),
        .init(lon: 114.17, lat: 22.32, aliases: ["hong kong", "hongkong", "hk", "香港", "深港"]),
        .init(lon: 113.54, lat: 22.20, aliases: ["macau", "macao", "mo", "澳门", "澳門"]),
        .init(lon: 121.56, lat: 25.03, aliases: ["taiwan", "taipei", "tw", "台湾", "臺灣", "台北", "新北", "彰化"]),
        .init(lon: 139.69, lat: 35.68, aliases: ["tokyo", "东京", "東京"]),
        .init(lon: 135.50, lat: 34.69, aliases: ["osaka", "大阪"]),
        .init(lon: 139.69, lat: 35.68, aliases: ["japan", "jp", "日本"]),
        .init(lon: 126.98, lat: 37.57, aliases: ["seoul", "首尔", "首爾"]),
        .init(lon: 126.98, lat: 37.57, aliases: ["korea", "kr", "韩国", "韓國"]),
        // China cities
        .init(lon: 116.40, lat: 39.90, aliases: ["beijing", "北京"]),
        .init(lon: 121.47, lat: 31.23, aliases: ["shanghai", "上海"]),
        .init(lon: 114.06, lat: 22.54, aliases: ["shenzhen", "深圳"]),
        .init(lon: 113.26, lat: 23.13, aliases: ["guangzhou", "广州", "廣州"]),
        .init(lon: 120.15, lat: 30.27, aliases: ["hangzhou", "杭州"]),
        .init(lon: 104.07, lat: 30.57, aliases: ["chengdu", "成都"]),
        .init(lon: 116.40, lat: 39.90, aliases: ["china", "cn", "中国", "中國", "国内", "回国", "回國"]),
        // South / Southeast Asia
        .init(lon: 100.50, lat: 13.75, aliases: ["bangkok", "thailand", "th", "泰国", "泰國", "曼谷"]),
        .init(lon: 101.69, lat: 3.14, aliases: ["kuala lumpur", "malaysia", "my", "马来西亚", "馬來西亞", "吉隆坡"]),
        .init(lon: 106.85, lat: -6.21, aliases: ["jakarta", "indonesia", "id", "印尼", "印度尼西亚", "雅加达"]),
        .init(lon: 120.98, lat: 14.60, aliases: ["manila", "philippines", "ph", "菲律宾", "菲律賓", "马尼拉"]),
        .init(lon: 105.85, lat: 21.03, aliases: ["hanoi", "vietnam", "vn", "越南", "河内"]),
        .init(lon: 72.88, lat: 19.08, aliases: ["mumbai", "india", "in", "印度", "孟买"]),
        .init(lon: 55.27, lat: 25.20, aliases: ["dubai", "uae", "ae", "阿联酋", "阿聯酋", "迪拜"]),
        // Oceania
        .init(lon: 151.21, lat: -33.87, aliases: ["sydney", "australia", "au", "澳大利亚", "澳洲", "悉尼"]),
        // Europe
        .init(lon: -0.13, lat: 51.51, aliases: ["london", "united kingdom", "uk", "gb", "britain", "england", "英国", "英國", "伦敦", "倫敦"]),
        .init(lon: 8.68, lat: 50.11, aliases: ["frankfurt", "germany", "de", "德国", "德國", "法兰克福", "法蘭克福"]),
        .init(lon: 4.90, lat: 52.37, aliases: ["amsterdam", "netherlands", "nl", "荷兰", "荷蘭", "阿姆斯特丹"]),
        .init(lon: 2.35, lat: 48.85, aliases: ["paris", "france", "fr", "法国", "法國", "巴黎"]),
        .init(lon: 37.62, lat: 55.75, aliases: ["moscow", "russia", "ru", "俄罗斯", "俄羅斯", "莫斯科"]),
        .init(lon: 28.98, lat: 41.01, aliases: ["istanbul", "turkey", "tr", "土耳其", "伊斯坦布尔"]),
        // Americas
        .init(lon: -118.24, lat: 34.05, aliases: ["los angeles", "洛杉矶", "洛杉磯"]),
        .init(lon: -121.89, lat: 37.34, aliases: ["san jose", "silicon valley", "san francisco", "sfo", "硅谷", "矽谷", "旧金山", "舊金山", "圣何塞"]),
        .init(lon: -74.0, lat: 40.71, aliases: ["new york", "nyc", "纽约", "紐約"]),
        .init(lon: -122.33, lat: 47.61, aliases: ["seattle", "西雅图", "西雅圖"]),
        .init(lon: -95.71, lat: 37.09, aliases: ["united states", "usa", "us", "america", "美国", "美國"]),
        .init(lon: -79.38, lat: 43.65, aliases: ["toronto", "canada", "加拿大", "多伦多"]),
        .init(lon: -46.63, lat: -23.55, aliases: ["sao paulo", "brazil", "br", "巴西", "圣保罗"]),
    ]

    /// Names that never carry geographic meaning and should not produce an arc.
    static let nonGeographic: Set<String> = ["direct", "reject", "reject-drop", "pass", "compatible", "global", "match"]

    static func isRoutable(_ name: String) -> Bool {
        !nonGeographic.contains(name.lowercased())
    }

    /// Resolve a single name to a coordinate, or nil when nothing matches.
    static func coordinate(for raw: String, egressCode: String? = nil) -> SIMD2<Double>? {
        let lower = raw.lowercased()
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        for place in places {
            for alias in place.aliases {
                if alias.allSatisfy(\.isASCII) {
                    if alias.count <= 2 {
                        if tokens.contains(alias) { return place.coordinate }
                    } else if lower.contains(alias) {
                        return place.coordinate
                    }
                } else if raw.contains(alias) {
                    return place.coordinate
                }
            }
        }

        if let code = flagISO2(in: raw), let c = WorldMapData.countryByCode[code] {
            return c
        }

        for (name, coord) in WorldMapData.countryByName {
            if name.contains(" ") {
                if lower.contains(name) { return coord }
            } else if tokens.contains(name) {
                return coord
            }
        }

        if let code = egressCode?.uppercased(), let c = WorldMapData.countryByCode[code] {
            return c
        }
        return nil
    }

    /// Pick the most meaningful proxy hop from a connection chain and resolve it.
    /// Returns the chosen label and its coordinate, or nil for direct / unresolvable flows.
    static func resolveChain(_ chain: [String], egressCode: String? = nil) -> (label: String, coordinate: SIMD2<Double>)? {
        let routable = chain.filter(isRoutable)
        guard !routable.isEmpty else { return nil }
        for name in routable {
            if let coord = coordinate(for: name, egressCode: nil) {
                return (cleanLabel(name), coord)
            }
        }
        // Names were cryptic but the flow is proxied — fall back to the session egress location.
        if let code = egressCode?.uppercased(), let coord = WorldMapData.countryByCode[code] {
            return (cleanLabel(routable.last ?? routable[0]), coord)
        }
        return nil
    }

    /// The local machine's approximate coordinate, from the system region.
    static func localCoordinate() -> SIMD2<Double> {
        if let region = Locale.current.region?.identifier.uppercased(),
           let c = WorldMapData.countryByCode[region] {
            return c
        }
        return .init(105.0, 35.0)
    }

    /// Decode a leading flag emoji (two regional-indicator symbols) into an ISO-3166 alpha-2 code.
    static func flagISO2(in text: String) -> String? {
        let indicators = text.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard indicators.count >= 2 else { return nil }
        let a = Character(UnicodeScalar(indicators[indicators.startIndex].value - 0x1F1E6 + 65)!)
        let b = Character(UnicodeScalar(indicators[indicators.index(after: indicators.startIndex)].value - 0x1F1E6 + 65)!)
        return String([a, b])
    }

    /// Trim flag emoji / leading symbols for a tidy on-map label.
    static func cleanLabel(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) }
        let s = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? raw : s
    }
}
