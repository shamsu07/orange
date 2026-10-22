import XCTest
@testable import Orange

final class WheelFeedbackTests: XCTestCase {
    @MainActor func testNativeOutputPreparesAndStopsWithoutPlaying() async throws {
        let audio = PreparedWheelAudio()
        defer { audio.stop() }
        try audio.prepare()
    }

    @MainActor func testPreparationIsReusedAndFeedbackDoesNotQueueOrRunWhileDismissed() async {
        let audio = FakeWheelAudio()
        var now = 10.0
        var creations = 0
        let feedback = WheelFeedback(makeOutput: { creations += 1; return audio }, uptime: { now })
        feedback.selection()
        XCTAssertTrue(audio.tones.isEmpty)
        feedback.prepare()
        feedback.prepare()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(audio.preparations, 1)
        feedback.selection()
        now += 0.020
        feedback.selection()
        XCTAssertEqual(audio.tones, [0])
        now += 0.030
        feedback.selection()
        now += 0.050
        feedback.selection()
        XCTAssertEqual(audio.tones, [0, 1, 0])
        feedback.stop()
        XCTAssertEqual(audio.stops, 1)
        now += 1
        feedback.selection()
        XCTAssertEqual(audio.tones, [0, 1, 0])
        feedback.prepare()
        feedback.selection()
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(audio.preparations, 2)
        XCTAssertEqual(audio.tones, [0, 1, 0, 0])
        feedback.stop()
    }

    @MainActor func testUnavailableAudioIsStoppedAndNeverBlocksAnotherPreparation() async {
        let audio = FakeWheelAudio()
        audio.failPreparation = true
        let feedback = WheelFeedback(makeOutput: { audio })
        feedback.prepare()
        feedback.selection()
        XCTAssertTrue(audio.tones.isEmpty)
        XCTAssertEqual(audio.stops, 1)
        audio.failPreparation = false
        feedback.prepare()
        feedback.selection()
        XCTAssertEqual(audio.preparations, 2)
        XCTAssertEqual(audio.tones, [0])
        feedback.stop()
        XCTAssertEqual(audio.stops, 2)
    }
}

@MainActor private final class FakeWheelAudio: WheelAudioOutput {
    private enum FixtureError: Error { case noDevice }
    var preparations = 0
    var tones: [Int] = []
    var stops = 0
    var failPreparation = false
    func prepare() throws {
        preparations += 1
        if failPreparation { throw FixtureError.noDevice }
    }
    func play(tone: Int) { tones.append(tone) }
    func stop() { stops += 1 }
}
