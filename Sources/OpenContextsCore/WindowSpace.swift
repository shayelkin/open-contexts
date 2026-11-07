import Foundation

public struct WindowSpace: Equatable, Sendable {
    public let id: UInt64
    public let index: Int
    public let isCurrent: Bool
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        /// A desktop, with the number Mission Control shows for it on its display.
        case desktop(number: Int)
        case fullscreen
    }

    public init(id: UInt64, index: Int, isCurrent: Bool, kind: Kind) {
        self.id = id
        self.index = index
        self.isCurrent = isCurrent
        self.kind = kind
    }
}

public enum WindowSwitcher {
    public static func filter(_ windows: [WindowInfo], query: String, allSpaces: Bool) -> [WindowSearch.Match] {
        guard allSpaces else { return WindowSearch.filter(windows.filter(\.isOnCurrentSpace), query: query) }
        let groups = Dictionary(grouping: windows) { $0.space?.id }.values.sorted { a, b in
            a[0].isOnCurrentSpace != b[0].isOnCurrentSpace ? a[0].isOnCurrentSpace
                : (a[0].space?.index ?? 0) < (b[0].space?.index ?? 0)
        }
        return groups.flatMap { group in
            WindowSearch.filter(group[0].isOnCurrentSpace ? group : group.sorted(by: alphabetically), query: query)
        }
    }

    private static func alphabetically(_ a: WindowInfo, _ b: WindowInfo) -> Bool {
        let appOrder = a.appName.localizedStandardCompare(b.appName)
        if appOrder != .orderedSame { return appOrder == .orderedAscending }
        switch a.displayTitle.localizedStandardCompare(b.displayTitle) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return a.id < b.id
        }
    }
}

public extension Sequence where Element == WindowInfo {
    func onVisibleSpaces(allSpaces: Bool) -> [WindowInfo] {
        allSpaces ? Array(self) : filter(\.isOnCurrentSpace)
    }
}
