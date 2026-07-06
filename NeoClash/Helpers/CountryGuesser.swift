import Foundation

/// Guesses the ISO 3166-1 alpha-2 country behind a proxy node name.
///
/// Matching order, most specific first:
///   1. A flag emoji embedded in the name (🇸🇬 → SG).
///   2. Common proxy-hub aliases (city / country names in English, 中文, and ISO codes).
///
/// Lives in the core target (unlike the map's `GeoLocator`, which resolves to coordinates)
/// so `RuntimeStore` can attribute traffic to countries while aggregating connections.
public enum CountryGuesser {
    private struct Entry {
        var code: String
        /// ASCII aliases ≤ 2 chars match as whole tokens, longer ones as substrings.
        /// CJK aliases match as substrings of the raw name.
        var aliases: [String]
    }

    // Ordered so a city wins over the country that contains it.
    private static let entries: [Entry] = [
        .init(code: "SG", aliases: ["singapore", "sg", "新加坡", "狮城", "獅城"]),
        .init(code: "HK", aliases: ["hong kong", "hongkong", "hk", "香港"]),
        .init(code: "MO", aliases: ["macau", "macao", "mo", "澳门", "澳門"]),
        .init(code: "TW", aliases: ["taiwan", "taipei", "tw", "台湾", "臺灣", "台北", "新北", "彰化"]),
        .init(code: "JP", aliases: ["tokyo", "osaka", "japan", "jp", "日本", "东京", "東京", "大阪"]),
        .init(code: "KR", aliases: ["seoul", "korea", "kr", "韩国", "韓國", "首尔", "首爾"]),
        .init(code: "CN", aliases: ["china", "cn", "中国", "中國", "国内", "回国", "回國", "北京", "上海", "深圳", "广州", "廣州", "杭州", "成都"]),
        .init(code: "TH", aliases: ["bangkok", "thailand", "th", "泰国", "泰國", "曼谷"]),
        .init(code: "MY", aliases: ["kuala lumpur", "malaysia", "my", "马来西亚", "馬來西亞", "吉隆坡"]),
        .init(code: "ID", aliases: ["jakarta", "indonesia", "id", "印尼", "印度尼西亚", "雅加达"]),
        .init(code: "PH", aliases: ["manila", "philippines", "ph", "菲律宾", "菲律賓", "马尼拉"]),
        .init(code: "VN", aliases: ["hanoi", "vietnam", "vn", "越南", "河内"]),
        .init(code: "IN", aliases: ["mumbai", "india", "in", "印度", "孟买"]),
        .init(code: "AE", aliases: ["dubai", "uae", "ae", "阿联酋", "阿聯酋", "迪拜"]),
        .init(code: "AU", aliases: ["sydney", "australia", "au", "澳大利亚", "澳洲", "悉尼"]),
        .init(code: "GB", aliases: ["london", "united kingdom", "uk", "gb", "britain", "england", "英国", "英國", "伦敦", "倫敦"]),
        .init(code: "DE", aliases: ["frankfurt", "germany", "de", "德国", "德國", "法兰克福", "法蘭克福"]),
        .init(code: "NL", aliases: ["amsterdam", "netherlands", "nl", "荷兰", "荷蘭", "阿姆斯特丹"]),
        .init(code: "FR", aliases: ["paris", "france", "fr", "法国", "法國", "巴黎"]),
        .init(code: "RU", aliases: ["moscow", "russia", "ru", "俄罗斯", "俄羅斯", "莫斯科"]),
        .init(code: "TR", aliases: ["istanbul", "turkey", "tr", "土耳其", "伊斯坦布尔"]),
        .init(code: "US", aliases: ["los angeles", "san jose", "silicon valley", "san francisco", "seattle", "new york", "united states", "usa", "us", "america", "美国", "美國", "洛杉矶", "洛杉磯", "硅谷", "矽谷", "旧金山", "舊金山", "圣何塞", "纽约", "紐約", "西雅图", "西雅圖"]),
        .init(code: "CA", aliases: ["toronto", "canada", "ca", "加拿大", "多伦多"]),
        .init(code: "BR", aliases: ["sao paulo", "brazil", "br", "巴西", "圣保罗"])
    ]

    /// Country code for a node name, or nil when nothing matches.
    public static func countryCode(for nodeName: String) -> String? {
        if let code = flagISO2(in: nodeName) {
            return code
        }

        let lower = nodeName.lowercased()
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        for entry in entries {
            for alias in entry.aliases {
                if alias.allSatisfy(\.isASCII) {
                    if alias.count <= 2 {
                        if tokens.contains(alias) { return entry.code }
                    } else if lower.contains(alias) {
                        return entry.code
                    }
                } else if nodeName.contains(alias) {
                    return entry.code
                }
            }
        }
        return nil
    }

    /// The first flag emoji in the string, decoded to its ISO code.
    public static func flagISO2(in text: String) -> String? {
        var letters = ""
        for scalar in text.unicodeScalars {
            if (0x1F1E6...0x1F1FF).contains(scalar.value) {
                letters.append(Character(UnicodeScalar(scalar.value - 0x1F1E6 + 0x41)!))
                if letters.count == 2 { return letters }
            } else if !letters.isEmpty {
                letters = ""
            }
        }
        return nil
    }

    /// Regional-indicator flag emoji for an ISO alpha-2 code (e.g. "HK" → 🇭🇰).
    public static func flagEmoji(for code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2, upper.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "🏳️" }
        return String(String.UnicodeScalarView(upper.unicodeScalars.compactMap {
            UnicodeScalar(0x1F1E6 + $0.value - 0x41)
        }))
    }

    /// Localized display name for an ISO code, falling back to the code itself.
    public static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
