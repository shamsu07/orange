import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class WheelAppearanceTests: XCTestCase {
    @MainActor func testRenderedGlassAndSolidUseDifferentOpacityIncludingCenter() throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            for (style, reduced, opaque) in [(WheelAppearance.glass, false, false), (.solid, false, true), (.glass, true, true)] {
                view.configure(choices: [.format(.jpeg), .format(.png)], mode: .convert, inputs: [],
                               appearance: style, diameter: 252, preview: true, byteCount: nil,
                               reduceTransparency: reduced)
                let layers = try XCTUnwrap(view.layer?.sublayers)
                let sector = try XCTUnwrap(layers.first?.sublayers?.first as? CAGradientLayer)
                let colors = try XCTUnwrap(sector.colors as? [CGColor])
                let center = try XCTUnwrap(layers.dropFirst(2).first as? CAShapeLayer)
                let centerColor = try XCTUnwrap(center.fillColor)
                for color in colors + [centerColor] {
                    if opaque { XCTAssertEqual(color.alpha, 1, accuracy: 0.001) }
                    else { XCTAssertLessThan(color.alpha, 0.5) }
                }
            }
        }
    }

    @MainActor func testVisiblePreviewUpdatesAppearanceAndSizeWithoutReopening() async throws {
        _ = NSApplication.shared
        let model = AppModel(persistPreferences: false)
        model.soundFeedback = false
        model.wheelDiameter = 252
        model.wheelAppearance = .glass
        let controller = DragWheelController(model: model)
        controller.preview()
        let view = try XCTUnwrap(controller.presentedWheel)
        let panel = try XCTUnwrap(view.window)
        let effect = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(effect.isHidden, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        model.wheelAppearance = .solid
        XCTAssertTrue(effect.isHidden)
        XCTAssertTrue(view.isPreview)
        let oldCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        model.wheelDiameter = 300
        XCTAssertEqual(panel.frame.width, 420, accuracy: 0.1)
        XCTAssertLessThan(abs(panel.frame.midX - oldCenter.x), 100)
        XCTAssertTrue(panel.isVisible)
        model.wheelAppearance = .glass
        XCTAssertEqual(effect.isHidden, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        await controller.stop()
        await model.shutdown()
        panel.close()
    }

    @MainActor func testAppearanceRefreshKeepsCurrentPageAndKeyboardChoice() throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let choices = OutputFormat.allCases.map(WheelChoice.format)
        let urls = [URL(fileURLWithPath: #filePath)]
        view.configure(choices: choices, mode: .convert, inputs: urls, appearance: .glass,
                       diameter: 252, preview: false, byteCount: 100, reduceTransparency: false)
        view.advancePage()
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: arrow)
        view.configure(choices: choices, mode: .convert, inputs: urls, appearance: .solid,
                       diameter: 252, preview: false, byteCount: 100, reduceTransparency: false)
        var committed: WheelChoice?
        view.onDrop = { choice, _ in committed = choice }
        let confirm = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36))
        view.keyDown(with: confirm)
        XCTAssertEqual(committed, choices[8])
    }
}
