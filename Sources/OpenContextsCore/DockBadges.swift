import Foundation

public enum DockBadges {
    public static func merged(
        _ badges: [String: String], activeAppIDs: Set<String>, reads: [String: String?]
    ) -> [String: String] {
        var merged = badges.filter { activeAppIDs.contains($0.key) }
        for (appID, raw) in reads.filter({ activeAppIDs.contains($0.key) }) {
            merged[appID] = raw.flatMap(self.displayValue)
        }
        return merged
    }

    public static func appID(for applicationURL: URL) -> String? {
        let url = applicationURL.standardizedFileURL
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        return Bundle(url: url)?.bundleIdentifier ?? url.path
    }

    static func displayValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let suffix = trimmed.hasSuffix("+") ? "+" : ""
        let digits = trimmed.utf8.dropLast(suffix.count)
        // Like UInt parsing, only ASCII digits count. Any all-digit text UInt can't parse
        // overflowed, so we return "99+".
        guard !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return "•"
        }
        switch UInt(Substring(digits)) ?? .max {
        case 0:
            return suffix.isEmpty ? nil : "•"
        case let count where count < 99 || (count == 99 && suffix.isEmpty):
            return "\(count)\(suffix)"
        default:
            return "99+"
        }
    }
}
