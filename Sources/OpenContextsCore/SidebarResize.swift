import CoreGraphics

public enum SidebarResize {
    public static func width(startWidth: CGFloat, startPointerX: CGFloat, pointerX: CGFloat,
                             dockedRight: Bool, range: ClosedRange<CGFloat>) -> CGFloat {
        let base = startWidth.isFinite ? startWidth : range.lowerBound
        let delta = pointerX - startPointerX
        let proposed = (base + (dockedRight ? -delta : delta)).rounded()
        let width = proposed.isFinite ? proposed : base.rounded()
        return min(max(width, range.lowerBound), range.upperBound)
    }
}
