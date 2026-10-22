import XCTest
@testable import Orange

final class WheelActivationTraceTests: XCTestCase {
    @MainActor func testSampledInputSkipsLiveStateQueriesWithoutDroppingTransitions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".cache/tests/trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("trace.jsonl")
        var now: TimeInterval = 100
        let trace = try WheelActivationTrace(url: url, uptime: { now })
        var queries = 0
        func liveState() -> [String: Any] { queries += 1; return ["query": queries] }
        trace.record("dragged", fields: liveState(), sample: "global.dragged")
        now += 0.001
        trace.record("dragged", fields: liveState(), sample: "global.dragged")
        XCTAssertEqual(queries, 1)
        trace.record("moved", fields: liveState(), sample: "recovery.moved")
        trace.record("cancelled", fields: liveState())
        now += 0.030
        trace.record("dragged", fields: liveState(), sample: "global.dragged")
        XCTAssertEqual(queries, 4)
        await trace.flush()
        let records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(records.compactMap { $0["event"] as? String }, ["dragged", "moved", "cancelled", "dragged"])
    }

    @MainActor func testTraceFlushPreservesRecordOrderAndAlwaysKeepsTransitions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".cache/tests/trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("trace.jsonl")
        let trace = try WheelActivationTrace(url: url)
        for index in 0..<20 { trace.record("transition", fields: ["generation": index]) }
        trace.record("movement", sample: "movement")
        trace.record("movement", sample: "movement")
        trace.record("failure", fields: ["reason": "native_callback_missing"])
        await trace.flush()
        let records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(records.prefix(20).compactMap { $0["generation"] as? Int }, Array(0..<20))
        XCTAssertEqual(records.compactMap { $0["ordinal"] as? Int }, Array(1...records.count))
        XCTAssertEqual(records.last?["event"] as? String, "failure")
        XCTAssertEqual(records.last?["reason"] as? String, "native_callback_missing")
        XCTAssertEqual(Set(records.compactMap { $0["run"] as? String }).count, 1)
        XCTAssertNotNil(records.first?["receivedUptime"] as? Double)
    }
}
