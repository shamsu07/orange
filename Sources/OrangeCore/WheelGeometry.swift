import CoreGraphics
import Foundation

/// Pure drawing and hit-testing geometry. Angles use Core Graphics coordinates:
/// zero points right and positive angles turn counterclockwise. Sector indices
/// advance clockwise from `startAngle`; returned ranges are ascending, unwrapped
/// radians, so drawing traverses each range from its upper to lower bound.
///
/// The 252-point default is inferred from a 504-pixel native wheel capture using
/// a 2x Retina mapping. Native point dimensions were not exposed by its API;
/// the configurable bounds remain Orange design choices.
public struct WheelGeometry: Sendable {
    public static let minimumDiameter: CGFloat = 220
    public static let maximumDiameter: CGFloat = 560
    public static let defaultDiameter: CGFloat = 252
    public static let defaultArcDegrees: CGFloat = 360
    public static let defaultStartAngle: CGFloat = .pi / 2
    public static let innerRadiusRatio: CGFloat = 0.34

    public let center: CGPoint
    public let diameter: CGFloat
    public let startAngle: CGFloat
    public let arcDegrees: CGFloat

    public var outerRadius: CGFloat { diameter / 2 }
    public var innerRadius: CGFloat { outerRadius * Self.innerRadiusRatio }
    public var arcRadians: CGFloat { arcDegrees * .pi / 180 }
    /// Unwrapped clockwise endpoint; it can be negative.
    public var endAngle: CGFloat { startAngle - arcRadians }

    /// A full wheel starts at the top by default. An upper semicircle that runs
    /// left to right is `startAngle: .pi, arcDegrees: 180`.
    ///
    /// Finite sizes clamp to 220...560; nonfinite sizes use 252. Finite arcs clamp
    /// to 0...360; zero disables sectors, and nonfinite arcs use a full circle.
    /// Nonfinite centers and start angles use `.zero` and the default angle.
    public init(center: CGPoint = .zero, preferredDiameter: CGFloat = WheelGeometry.defaultDiameter,
                startAngle: CGFloat = WheelGeometry.defaultStartAngle, arcDegrees: CGFloat = WheelGeometry.defaultArcDegrees) {
        self.center = center.x.isFinite && center.y.isFinite ? center : .zero
        let size = preferredDiameter.isFinite ? preferredDiameter : Self.defaultDiameter
        diameter = min(max(size, Self.minimumDiameter), Self.maximumDiameter)
        self.startAngle = Self.normalized(startAngle.isFinite ? startAngle : Self.defaultStartAngle)
        self.arcDegrees = arcDegrees.isFinite ? min(max(arcDegrees, 0), 360) : Self.defaultArcDegrees
    }

    /// Invalid indices, empty selections and zero-length arcs have no sector.
    public func sectorAngle(index: Int, count: Int) -> ClosedRange<CGFloat>? {
        guard count > 0, index >= 0, index < count, arcDegrees > 0 else { return nil }
        let step = arcRadians / CGFloat(count)
        let upper = startAngle - CGFloat(index) * step
        let lower = index == count - 1 ? endAngle : startAngle - CGFloat(index + 1) * step
        return lower...upper
    }

    /// Both annular radii and the arc endpoints are included. A shared sector
    /// boundary belongs to the next clockwise sector. The final endpoint of a
    /// partial arc belongs to its last sector. A full circle's coincident start
    /// and end point belongs to sector zero.
    public func hitTest(point: CGPoint, itemCount: Int) -> Int? {
        guard itemCount > 0, arcDegrees > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = hypot(dx, dy)
        let radialTolerance = outerRadius * CGFloat.ulpOfOne * 8
        guard radius.isFinite, radius >= innerRadius - radialTolerance,
              radius <= outerRadius + radialTolerance else { return nil }

        let turn: CGFloat = 2 * .pi
        let angularTolerance = turn * CGFloat.ulpOfOne * 8
        var offset = Self.normalized(startAngle - atan2(dy, dx))
        // atan2 can represent the start point on the other side of the wrap.
        if turn - offset <= angularTolerance { offset = 0 }
        guard offset <= arcRadians + angularTolerance else { return nil }
        var position = min(offset, arcRadians) / arcRadians * CGFloat(itemCount)
        let nearestBoundary = position.rounded()
        if abs(position - nearestBoundary) <= CGFloat.ulpOfOne * 16 * max(1, abs(position)) {
            position = nearestBoundary
        }
        // Check before converting to Int, including when CGFloat(Int.max) rounds
        // upward to a value that cannot itself be represented as an Int.
        if position >= CGFloat(itemCount - 1) { return itemCount - 1 }
        return max(0, Int(position))
    }

    private static func normalized(_ angle: CGFloat) -> CGFloat {
        let turn: CGFloat = 2 * .pi
        let remainder = angle.truncatingRemainder(dividingBy: turn)
        return remainder < 0 ? remainder + turn : remainder
    }
}
