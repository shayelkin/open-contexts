import CoreGraphics
import Foundation

public enum SidebarTooltipLayout {
    public static let pointerClearance: CGFloat = 20
    public static let gap: CGFloat = 4
    public static let initialDelayDefaultsKey = "NSInitialToolTipDelay"
    public static let fallbackInitialDelay: TimeInterval = 1.5

    public static func initialDelay(milliseconds: Any?) -> TimeInterval {
        let value: Double? = switch milliseconds {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
        guard let value, value.isFinite, value >= 0 else { return fallbackInitialDelay }
        return value / 1000
    }

    public static func needsTooltip(showsTitle: Bool, titleWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        !showsTitle || titleWidth > availableWidth
    }

    public static func frame(size: CGSize, pointer: CGPoint, screen: CGRect) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let below = pointer.y - pointerClearance - height
        let y = below >= screen.minY ? below : pointer.y + gap
        return CGRect(x: min(max(pointer.x, screen.minX), screen.maxX - width),
                      y: min(max(y, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}
