import CoreGraphics
import XCTest
@testable import OrangeCore

final class WheelGeometryTests: XCTestCase {
    func testDiameterClampsAndInnerRadiusTracksItsSize() {
        let minimum = WheelGeometry(preferredDiameter: 10)
        let maximum = WheelGeometry(preferredDiameter: 10_000)
        let normal = WheelGeometry(preferredDiameter: 420)
        XCTAssertEqual(minimum.diameter, WheelGeometry.minimumDiameter)
        XCTAssertEqual(maximum.diameter, WheelGeometry.maximumDiameter)
        XCTAssertEqual(normal.outerRadius, 210)
        XCTAssertEqual(normal.innerRadius, 210 * 0.34, accuracy: 1e-12)
        XCTAssertEqual(WheelGeometry().diameter, WheelGeometry.defaultDiameter)
        XCTAssertEqual(WheelGeometry().arcDegrees, 360)
    }

    func testNonfiniteSettingsHaveFiniteDocumentedDefaults() {
        for size in [CGFloat.nan, .infinity, -.infinity] {
            let geometry = WheelGeometry(center: CGPoint(x: CGFloat.infinity, y: 12), preferredDiameter: size,
                                         startAngle: .nan, arcDegrees: .nan)
            XCTAssertEqual(geometry.center, .zero)
            XCTAssertEqual(geometry.diameter, WheelGeometry.defaultDiameter)
            XCTAssertEqual(geometry.startAngle, WheelGeometry.defaultStartAngle)
            XCTAssertEqual(geometry.arcDegrees, 360)
            XCTAssertTrue(geometry.endAngle.isFinite)
        }
        XCTAssertEqual(WheelGeometry(arcDegrees: 500).arcDegrees, 360)
        XCTAssertEqual(WheelGeometry(arcDegrees: -30).arcDegrees, 0)
    }

    func testEverySectorCenterHitsItsOwnSectorForFullAndHalfWheels() throws {
        for geometry in [WheelGeometry(center: CGPoint(x: 300, y: 220)),
                         WheelGeometry(center: CGPoint(x: -30, y: 90), startAngle: .pi, arcDegrees: 180)] {
            for count in [1, 2, 3, 7, 8, 12] {
                for index in 0..<count {
                    let sector = try XCTUnwrap(geometry.sectorAngle(index: index, count: count))
                    let angle = (sector.lowerBound + sector.upperBound) / 2
                    let radius = (geometry.innerRadius + geometry.outerRadius) / 2
                    XCTAssertEqual(geometry.hitTest(point: point(geometry, angle: angle, radius: radius), itemCount: count), index)
                    XCTAssertEqual(sector.upperBound - sector.lowerBound, geometry.arcRadians / CGFloat(count), accuracy: 1e-12)
                }
            }
        }
    }

    func testAnnularBoundsAreInclusiveAndCenterIsExcluded() {
        let geometry = WheelGeometry(center: CGPoint(x: 50, y: -20))
        let angle: CGFloat = 0.3
        XCTAssertNotNil(geometry.hitTest(point: point(geometry, angle: angle, radius: geometry.innerRadius), itemCount: 6))
        XCTAssertNotNil(geometry.hitTest(point: point(geometry, angle: angle, radius: geometry.outerRadius), itemCount: 6))
        XCTAssertNil(geometry.hitTest(point: geometry.center, itemCount: 6))
        XCTAssertNil(geometry.hitTest(point: point(geometry, angle: angle, radius: geometry.innerRadius - 0.01), itemCount: 6))
        XCTAssertNil(geometry.hitTest(point: point(geometry, angle: angle, radius: geometry.outerRadius + 0.01), itemCount: 6))
    }

    func testUpperSemicircleRejectsLowerHalfAndIncludesPiAndZeroEndpoints() {
        let half = WheelGeometry(startAngle: .pi, arcDegrees: 180)
        let radius = (half.innerRadius + half.outerRadius) / 2
        XCTAssertEqual(half.hitTest(point: CGPoint(x: -radius, y: 0), itemCount: 4), 0)
        XCTAssertEqual(half.hitTest(point: CGPoint(x: radius, y: 0), itemCount: 4), 3)
        XCTAssertNil(half.hitTest(point: CGPoint(x: 0, y: -radius), itemCount: 4))
        XCTAssertNotNil(WheelGeometry().hitTest(point: CGPoint(x: 0, y: -radius), itemCount: 4))
        XCTAssertEqual(half.endAngle, 0, accuracy: 1e-12)
    }

    func testSharedBoundariesBelongToNextClockwiseSector() {
        let half = WheelGeometry(startAngle: .pi, arcDegrees: 180)
        let radius = (half.innerRadius + half.outerRadius) / 2
        for (angle, expected) in [(CGFloat.pi, 0), (.pi * 0.75, 1), (.pi * 0.5, 2), (.pi * 0.25, 3), (0, 3)] {
            XCTAssertEqual(half.hitTest(point: point(half, angle: angle, radius: radius), itemCount: 4), expected)
        }
        let full = WheelGeometry()
        XCTAssertEqual(full.hitTest(point: point(full, angle: full.startAngle, radius: radius), itemCount: 8), 0)
        XCTAssertEqual(full.hitTest(point: point(full, angle: full.endAngle, radius: radius), itemCount: 8), 0)
    }

    func testTopCenteredEightSectorConfigurationAdvancesClockwise() throws {
        let count = 8
        let geometry = WheelGeometry(startAngle: .pi / 2 + .pi / CGFloat(count))
        let first = try XCTUnwrap(geometry.sectorAngle(index: 0, count: count))
        XCTAssertEqual((first.lowerBound + first.upperBound) / 2, .pi / 2, accuracy: 1e-12)
        let radius = (geometry.innerRadius + geometry.outerRadius) / 2
        XCTAssertEqual(geometry.hitTest(point: CGPoint(x: 0, y: radius), itemCount: count), 0)
        XCTAssertEqual(geometry.hitTest(point: point(geometry, angle: .pi / 4, radius: radius), itemCount: count), 1)
        XCTAssertEqual(geometry.hitTest(point: CGPoint(x: radius, y: 0), itemCount: count), 2)
    }

    func testArcWrappingAndClockwiseOrderingUseUnwrappedRanges() throws {
        let geometry = WheelGeometry(startAngle: .pi / 4, arcDegrees: 180)
        let first = try XCTUnwrap(geometry.sectorAngle(index: 0, count: 2))
        let second = try XCTUnwrap(geometry.sectorAngle(index: 1, count: 2))
        XCTAssertEqual(first.upperBound, .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(first.lowerBound, -.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(second.lowerBound, -.pi * 0.75, accuracy: 1e-12)
        let radius = (geometry.innerRadius + geometry.outerRadius) / 2
        XCTAssertEqual(geometry.hitTest(point: point(geometry, angle: 0, radius: radius), itemCount: 2), 0)
        XCTAssertEqual(geometry.hitTest(point: point(geometry, angle: -.pi / 2, radius: radius), itemCount: 2), 1)
        XCTAssertNil(geometry.hitTest(point: point(geometry, angle: .pi / 2, radius: radius), itemCount: 2))
    }

    func testInvalidCountsIndicesPointsAndZeroArcsAreSafe() {
        let geometry = WheelGeometry()
        let validPoint = CGPoint(x: 100, y: 0)
        for count in [0, -1, Int.min] {
            XCTAssertNil(geometry.hitTest(point: validPoint, itemCount: count))
            XCTAssertNil(geometry.sectorAngle(index: 0, count: count))
        }
        XCTAssertNil(geometry.sectorAngle(index: -1, count: 3))
        XCTAssertNil(geometry.sectorAngle(index: 3, count: 3))
        for invalidPoint in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity),
                             CGPoint(x: -CGFloat.infinity, y: CGFloat.nan), CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)] {
            XCTAssertNil(geometry.hitTest(point: invalidPoint, itemCount: 8))
        }
        let zero = WheelGeometry(arcDegrees: 0)
        XCTAssertNil(zero.sectorAngle(index: 0, count: 1))
        XCTAssertNil(zero.hitTest(point: validPoint, itemCount: 1))
        XCTAssertNotNil(geometry.hitTest(point: validPoint, itemCount: Int.max))
    }

    private func point(_ geometry: WheelGeometry, angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: geometry.center.x + cos(angle) * radius, y: geometry.center.y + sin(angle) * radius)
    }
}
