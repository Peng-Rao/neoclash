import Foundation

public enum Redactor {
    public static func redact(_ text: String) -> String {
        var output = text
        output = replace(pattern: #"https?://[^\s"')<>\]]+"#, in: output, with: "https://<redacted>")
        output = replace(pattern: #"(?i)(authorization)\s*[:=]\s*Bearer\s+[A-Za-z0-9._~+/=-]+"#, in: output, with: "$1: Bearer <redacted>")
        output = replace(pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#, in: output, with: "Bearer <redacted>")
        output = replace(pattern: #"(?i)(secret|password|token)\s*[:=]\s*["']?[^"'\s,}]+"#, in: output, with: "$1: <redacted>")
        return output
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
