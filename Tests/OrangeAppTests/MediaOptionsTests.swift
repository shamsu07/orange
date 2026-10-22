import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class MediaOptionsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ name: String = "clip.mp4", duration: Double = 60, video: Bool = true, audio: Bool = true,
                        frameRate: Double? = 30) -> MediaSource {
        MediaSource(url: root.appendingPathComponent(".cache/tests/\(name)"), duration: duration,
                    hasVideo: video, hasAudio: audio, byteCount: 1_000_000, frameRate: frameRate)
    }

    @MainActor func testSnapshotStartsInTheMiddleAndExportsTheChosenFrameTime() throws {
        let item = source(duration: 80)
        var settings = ConversionSettings()
        settings.quality = 0.91
        let model = MediaOptionsModel(sources: [item], tool: .snapshot, settings: settings)
        XCTAssertEqual(model.draft.snapshot, 40)
        XCTAssertNil(model.validationMessage)
        model.setText(\.snapshotText, "12.345")
        let selection = try XCTUnwrap(model.confirmCurrent()?.first)
        XCTAssertEqual(selection.input, item.url)
        XCTAssertEqual(selection.settings.trimStart, 12.345)
        XCTAssertEqual(selection.settings.quality, settings.quality)
    }

    @MainActor func testSnapshotRejectsInvalidAndEndOfStreamTimes() throws {
        let model = MediaOptionsModel(sources: [source(duration: 2)], tool: .snapshot, settings: ConversionSettings())
        for text in ["", "-1", "nan", "inf", "2", "100", "halfway"] {
            model.setText(\.snapshotText, text)
            XCTAssertNotNil(model.validationMessage, text)
            XCTAssertNil(model.confirmCurrent(), text)
        }
        model.setText(\.snapshotText, "0")
        XCTAssertNil(model.validationMessage)
    }

    @MainActor func testSnapshotLastFrameRoundingClampsExportToTheActualLimit() throws {
        let item = source(duration: 1, frameRate: 30)
        let model = MediaOptionsModel(sources: [item], tool: .snapshot, settings: ConversionSettings())
        model.setText(\.snapshotText, MediaOptionsModel.number(item.lastFrameTime))
        XCTAssertNil(model.validationMessage)
        XCTAssertEqual(try XCTUnwrap(model.confirmCurrent()?.first).settings.trimStart, item.lastFrameTime, accuracy: 0.0000001)
    }

    @MainActor func testBatchRequiresEachFileToBeReviewedAndRetainsIndependentTimes() throws {
        let first = source("first.mp4", duration: 20), second = source("second.mp4", duration: 100)
        let model = MediaOptionsModel(sources: [first, second], tool: .snapshot, settings: ConversionSettings())
        XCTAssertEqual(model.draft.snapshot, 10)
        XCTAssertFalse(model.isLastReview)
        model.setText(\.snapshotText, "3")
        XCTAssertNil(model.confirmCurrent())
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.draft.snapshot, 50)
        XCTAssertTrue(model.isLastReview)
        model.setText(\.snapshotText, "77")
        let selected = try XCTUnwrap(model.confirmCurrent())
        XCTAssertEqual(selected.map(\.input), [first.url, second.url])
        XCTAssertEqual(selected.map(\.settings.trimStart), [3, 77])
    }

    @MainActor func testRevisingReviewedFileRequiresReviewAgain() throws {
        let model = MediaOptionsModel(sources: [source("first.mp4"), source("second.mp4")], tool: .snapshot, settings: ConversionSettings())
        XCTAssertNil(model.confirmCurrent())
        XCTAssertTrue(model.reviewed.contains(0))
        model.move(to: 0)
        model.setText(\.snapshotText, "4")
        XCTAssertFalse(model.reviewed.contains(0))
        model.move(to: 1)
        XCTAssertNil(model.confirmCurrent())
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.draft.snapshot, 4)
    }

    @MainActor func testTrimRejectsUnchangedOrInvalidRangesAndPreviewsOutputDuration() throws {
        let model = MediaOptionsModel(sources: [source(duration: 60)], tool: .trim, settings: ConversionSettings())
        XCTAssertTrue(try XCTUnwrap(model.validationMessage).contains("shorten"))
        XCTAssertNil(model.confirmCurrent())
        for (start, end) in [("-1", "20"), ("30", "20"), ("20", "20"), ("0", "61"), ("nan", "20"), ("10", "inf"), ("", "20")] {
            model.setText(\.startText, start); model.setText(\.endText, end)
            XCTAssertNotNil(model.validationMessage)
            XCTAssertNil(model.confirmCurrent())
        }
        model.setText(\.startText, "10.25"); model.setText(\.endText, "20.5")
        XCTAssertEqual(model.outputDuration, 10.25)
        let value = try XCTUnwrap(model.confirmCurrent()?.first).settings
        XCTAssertEqual(value.trimStart, 10.25)
        XCTAssertEqual(value.trimEnd, 20.5)
    }

    @MainActor func testTrimBatchKeepsDifferentRangesForDifferentDurations() throws {
        let model = MediaOptionsModel(sources: [source("one.mp4", duration: 10), source("two.mp4", duration: 100)],
                                      tool: .trim, settings: ConversionSettings())
        model.setText(\.startText, "1"); model.setText(\.endText, "9")
        XCTAssertNil(model.confirmCurrent())
        XCTAssertEqual(model.draft.end, 100)
        model.setText(\.startText, "20"); model.setText(\.endText, "80")
        let result = try XCTUnwrap(model.confirmCurrent())
        XCTAssertEqual(result.map(\.settings.trimStart), [1, 20])
        XCTAssertEqual(result.compactMap(\.settings.trimEnd), [9, 80])
    }

    @MainActor func testSpeedChangesDurationAndValidatesBounds() throws {
        let model = MediaOptionsModel(sources: [source(duration: 120)], tool: .changeSpeed, settings: ConversionSettings())
        XCTAssertEqual(model.draft.speed, 1.5)
        XCTAssertEqual(model.outputDuration, 80)
        for speed in [Double.nan, Double.infinity, 0, 0.2, 1, 4.1] {
            model.setSpeed(speed)
            XCTAssertNotNil(model.validationMessage)
            XCTAssertNil(model.confirmCurrent())
        }
        model.setSpeed(0.5)
        XCTAssertEqual(model.outputDuration, 240)
        XCTAssertEqual(try XCTUnwrap(model.confirmCurrent()?.first).settings.speed, 0.5)
    }

    @MainActor func testCompressionUsesChosenQualityWithoutChangingOtherSettings() throws {
        var base = ConversionSettings()
        base.stripMetadata = true
        let model = MediaOptionsModel(sources: [source()], tool: .compress, settings: base)
        model.setQuality(0.4)
        let settings = try XCTUnwrap(model.confirmCurrent()?.first).settings
        XCTAssertEqual(settings.quality, 0.4)
        XCTAssertTrue(settings.stripMetadata)
        XCTAssertEqual(settings.speed, 1)
    }

    @MainActor func testAudioOnlySourceCannotConfirmSnapshotOrMissingAudioTools() {
        let snapshot = MediaOptionsModel(sources: [source(video: false)], tool: .snapshot, settings: ConversionSettings())
        XCTAssertNotNil(snapshot.validationMessage)
        XCTAssertNil(snapshot.confirmCurrent())
        for tool in [ToolKind.extractAudio, .normalizeAudio] {
            let noAudio = MediaOptionsModel(sources: [source(audio: false)], tool: tool, settings: ConversionSettings())
            XCTAssertNotNil(noAudio.validationMessage)
            XCTAssertNil(noAudio.confirmCurrent())
        }
    }

    @MainActor func testCancelImmediatelyDoesNotReturnPreparedSelectionsOrErrors() async throws {
        _ = NSApplication.shared
        let presenter = MediaOptionsCoordinator()
        var callbacks = 0
        presenter.choose([source().url], tool: .snapshot, settings: ConversionSettings()) { result in
            callbacks += 1
            switch result {
            case .success(let value): XCTAssertNil(value)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
        }
        presenter.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callbacks, 1)
        presenter.cancel()
        XCTAssertEqual(callbacks, 1)
    }

    @MainActor func testPreviewStopReleasesPlayerAndResetsPresentation() {
        let preview = MediaPreviewModel()
        preview.stop()
        XCTAssertNil(preview.player.currentItem)
        XCTAssertNil(preview.frame)
        XCTAssertFalse(preview.isPlaying)
        XCTAssertFalse(preview.loadingFrame)
        XCTAssertFalse(preview.playbackAvailable)
    }

    @MainActor func testShutdownJoinsRetiredFramesAndKeepsPreviewWorkersWithinTheSharedLimit() async throws {
        let workers = PreviewTaskGroup()
        let gate = PreviewLifecycleTestGate()
        let previews = (0..<3).map { index in
            let preview = MediaPreviewModel(tasks: workers) { _, _ in
                await gate.hold()
                return Data()
            }
            preview.load(source("retired-\(index).mp4"), time: 1)
            return preview
        }
        let deadline = Date().addingTimeInterval(3)
        while await gate.started < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await gate.started
        XCTAssertEqual(started, 2)
        guard started == 2 else { previews.forEach { $0.stop() }; await gate.releaseAll(); await workers.shutdown(); return }
        try await Task.sleep(for: .milliseconds(30))
        let beforeCancel = await gate.started
        XCTAssertEqual(beforeCancel, 2, "The third preview must wait for the same two permits used by conversions.")

        previews.forEach { $0.stop() }
        let coordinator = MediaOptionsCoordinator(tasks: workers)
        var shutdownFinished = false
        let shutdown = Task { await coordinator.shutdown(); shutdownFinished = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(shutdownFinished, "Cancelled frame decoders still own resources until their workers return.")
        await gate.releaseAll()
        await shutdown.value
        let maximumActive = await gate.maximumActive
        let totalStarted = await gate.started
        let cancelledOnReturn = await gate.cancelledOnReturn
        XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(totalStarted, 2, "Cancellation must remove the queued third preview without decoding it.")
        XCTAssertEqual(cancelledOnReturn, 2)
        XCTAssertTrue(workers.isShutdown)
        for preview in previews {
            XCTAssertNil(preview.frame)
            XCTAssertFalse(preview.loadingFrame)
            XCTAssertFalse(preview.isPlaying)
            XCTAssertNil(preview.player.currentItem)
            preview.load(source(), time: 0)
            XCTAssertNil(preview.player.currentItem)
            XCTAssertFalse(preview.loadingFrame, "Late view callbacks cannot restart a stopped preview group.")
        }
        var callbacks = 0
        coordinator.choose([source().url], tool: .snapshot, settings: ConversionSettings()) { result in
            callbacks += 1
            guard case .success(nil) = result else { return XCTFail("A stopped coordinator must reject new work.") }
        }
        XCTAssertEqual(callbacks, 1)
    }

    @MainActor func testTimeFormatterRejectsNonFiniteAndUnrepresentableDurations() {
        for value in [Double.nan, Double.infinity, -1, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(MediaOptionsModel.time(value), "—")
        }
        XCTAssertEqual(MediaOptionsModel.time(3723.25), "1:02:03.25")
    }
}
