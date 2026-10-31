import CoreGraphics
import Foundation

public enum SidebarReveal {
    public enum Edge: CaseIterable {
        case left, right, bottom
    }

    public static let duration: TimeInterval = 0.2

    public static func eased(_ progress: Double) -> Double {
        1 - pow(1 - clamped(progress), 3)
    }

    public static func step(progress: Double, toward target: Double, elapsed: TimeInterval,
                            duration: TimeInterval = duration) -> Double {
        let target = clamped(target)
        let progress = clamped(progress)
        guard duration > 0, elapsed.isFinite else { return target }
        let distance = max(elapsed, 0) / duration
        return progress < target ? min(progress + distance, target) : max(progress - distance, target)
    }

    public static func frame(expanded: CGRect, edge: Edge, progress: Double) -> CGRect {
        let fraction = CGFloat(eased(progress))
        switch edge {
        case .left:
            return CGRect(x: expanded.minX, y: expanded.minY,
                          width: max(expanded.width * fraction, 1), height: expanded.height)
        case .right:
            let width = max(expanded.width * fraction, 1)
            return CGRect(x: expanded.maxX - width, y: expanded.minY, width: width, height: expanded.height)
        case .bottom:
            return CGRect(x: expanded.minX, y: expanded.minY,
                          width: expanded.width, height: max(expanded.height * fraction, 1))
        }
    }

    private static func clamped(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}
