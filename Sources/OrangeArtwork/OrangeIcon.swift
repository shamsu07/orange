import AppKit

/// Original vector artwork, shared by the app and the packaged icon generator.
public enum OrangeIcon {
    public static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    public static func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let edge = min(rect.width, rect.height)
        context.saveGState()
        defer { context.restoreGState() }
        let tile = rect.insetBy(dx: edge * 0.055, dy: edge * 0.055)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: edge * 0.20, cornerHeight: edge * 0.20, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -edge * 0.018), blur: edge * 0.025,
                          color: NSColor(calibratedRed: 0.50, green: 0.25, blue: 0, alpha: 0.23).cgColor)
        context.addPath(tilePath)
        context.setFillColor(NSColor(calibratedRed: 1, green: 0.92, blue: 0.72, alpha: 1).cgColor)
        context.fillPath()
        context.restoreGState()
        fill(tilePath, top: color(1, 0.97, 0.89), bottom: color(1, 0.87, 0.61), context: context)
        context.addPath(tilePath)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(edge * 0.002)
        context.strokePath()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer: CGFloat = edge * 0.36
        let inner: CGFloat = edge * 0.133
        let peel = CGPath(ellipseIn: CGRect(x: center.x - outer - edge * 0.018, y: center.y - outer - edge * 0.018,
                                           width: 2 * (outer + edge * 0.018), height: 2 * (outer + edge * 0.018)), transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -edge * 0.012), blur: edge * 0.014,
                          color: NSColor(calibratedRed: 0.70, green: 0.31, blue: 0, alpha: 0.28).cgColor)
        fill(peel, top: color(1, 0.77, 0.27), bottom: color(0.93, 0.47, 0), context: context)
        context.restoreGState()
        let pith = CGPath(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2), transform: nil)
        fill(pith, top: color(1, 0.98, 0.88), bottom: color(1, 0.91, 0.68), context: context)
        for index in 0..<7 {
            let middle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / 7
            let path = segment(center: center, outer: outer - edge * 0.009, inner: inner,
                               upper: middle + .pi / 7, lower: middle - .pi / 7, gap: edge * 0.0045, corner: edge * 0.025)
            let selected = index == 3
            fill(path, top: selected ? color(1, 0.66, 0.06) : color(1, 0.76, 0.27),
                 bottom: selected ? color(0.96, 0.46, 0) : color(1, 0.56, 0), context: context)
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(edge * 0.0025)
            context.strokePath()
        }
        let pill = CGRect(x: center.x - edge * 0.087, y: center.y - edge * 0.041, width: edge * 0.174, height: edge * 0.082)
        let pillPath = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -edge * 0.004), blur: edge * 0.006,
                          color: NSColor(calibratedRed: 0.70, green: 0.34, blue: 0, alpha: 0.22).cgColor)
        fill(pillPath, top: color(1, 0.76, 0.22), bottom: color(1, 0.58, 0), context: context)
        context.restoreGState()
    }

    public static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for index in 0..<7 {
                let middle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / 7
                context.addPath(segment(center: CGPoint(x: 9, y: 9), outer: 8, inner: 3,
                                        upper: middle + .pi / 7, lower: middle - .pi / 7, gap: 0.3, corner: 0.7))
            }
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.fill(CGRect(x: 7.5, y: 8.25, width: 3, height: 1.5))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Orange"
        return image
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor
    }
    private static func fill(_ path: CGPath, top: CGColor, bottom: CGColor, context: CGContext) {
        let bounds = path.boundingBox
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY), end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
        }
        context.restoreGState()
    }
    private static func segment(center: CGPoint, outer: CGFloat, inner: CGFloat, upper: CGFloat, lower: CGFloat,
                                gap: CGFloat, corner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let outerGap = gap / outer
        let innerGap = gap / inner
        let innerCorner = corner * 0.45
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        path.move(to: point(outer, upper - outerGap - corner / outer))
        path.addArc(center: center, radius: outer, startAngle: upper - outerGap - corner / outer,
                    endAngle: lower + outerGap + corner / outer, clockwise: true)
        path.addQuadCurve(to: point(outer - corner, lower + outerGap), control: point(outer, lower + outerGap))
        path.addLine(to: point(inner + innerCorner, lower + innerGap))
        path.addQuadCurve(to: point(inner, lower + innerGap + innerCorner / inner), control: point(inner, lower + innerGap))
        path.addArc(center: center, radius: inner, startAngle: lower + innerGap + innerCorner / inner,
                    endAngle: upper - innerGap - innerCorner / inner, clockwise: false)
        path.addQuadCurve(to: point(inner + innerCorner, upper - innerGap), control: point(inner, upper - innerGap))
        path.addLine(to: point(outer - corner, upper - outerGap))
        path.addQuadCurve(to: point(outer, upper - outerGap - corner / outer), control: point(outer, upper - outerGap))
        path.closeSubpath()
        return path
    }
}
