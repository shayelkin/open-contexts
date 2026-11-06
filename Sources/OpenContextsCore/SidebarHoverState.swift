import CoreGraphics
import Foundation

public struct SidebarHoverState: Equatable {
    public private(set) var isExpanded: Bool
    private var outsideSince: TimeInterval?

    public init(isExpanded: Bool = false) {
        self.isExpanded = isExpanded
    }

    // Stretches the edge strip along the whole side of the screen. The far end is inclusive because
    // the pointer can rest exactly on the screen's maximum coordinate.
    public static func edgeTriggerFrame(edge: CGRect, screen: CGRect, vertical: Bool) -> CGRect {
        vertical
            ? CGRect(x: edge.minX, y: screen.minY, width: edge.width, height: screen.height + 1)
            : CGRect(x: screen.minX, y: edge.minY, width: screen.width + 1, height: edge.height)
    }

    /// When the pending collapse happens if the pointer stays outside; nil when none is pending.
    public func collapseDeadline(collapseDelay: TimeInterval = defaultCollapseDelay) -> TimeInterval? {
        guard isExpanded, let outsideSince else { return nil }
        return outsideSince + max(collapseDelay, 0)
    }

    public static let defaultCollapseDelay: TimeInterval = 0.12

    @discardableResult
    public mutating func update(pointer: CGPoint, edgeFrame: CGRect, expandedFrame: CGRect,
                                dragging: Bool, menuOpen: Bool = false, now: TimeInterval,
                                collapseDelay: TimeInterval = defaultCollapseDelay) -> Bool {
        let previous = isExpanded
        if dragging || menuOpen {
            isExpanded = true
            outsideSince = nil
        } else if !isExpanded {
            if edgeFrame.contains(pointer) { isExpanded = true }
            outsideSince = nil
        } else if expandedFrame.contains(pointer) || edgeFrame.contains(pointer) {
            outsideSince = nil
        } else if let outsideSince, now >= outsideSince {
            if now - outsideSince >= max(collapseDelay, 0) {
                isExpanded = false
                self.outsideSince = nil
            }
        } else {
            outsideSince = now
        }
        return previous != isExpanded
    }
}
