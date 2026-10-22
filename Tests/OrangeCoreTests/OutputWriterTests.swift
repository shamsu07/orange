import Foundation
import XCTest
@testable import OrangeCore

final class OutputWriterTests: XCTestCase {
    private var directory: URL!
    private enum FixtureError: Error { case expected }

    override func setUpWithError() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("Run tests from the Orange workspace so fixtures stay inside the project.")
        }
        directory = workspace.appendingPathComponent(".cache/tests/output-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testSameExtensionPreservesSourceAndExistingNumberedOutput() throws {
        let original = Data("original bytes".utf8)
        let existing = Data("previous conversion".utf8)
        let input = try write("sample.bin", data: original)
        let previous = try write("sample 1.bin", data: existing)
        let converted = Data("new conversion".utf8)

        let output = try OutputWriter.write(beside: input, extension: "bin") { stage in
            try converted.write(to: stage)
        }

        XCTAssertEqual(output.lastPathComponent, "sample 2.bin")
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: previous), existing)
        XCTAssertEqual(try Data(contentsOf: output), converted)
        try assertNoStages()
    }

    func testConcurrentPublicationsHaveUniqueNamesAndKeepTheirOwnBytes() async throws {
        let input = try write("concurrent.source", data: Data("source sentinel".utf8))
        let sentinel = Data("existing destination".utf8)
        let collision = try write("concurrent.bin", data: sentinel)
        let count = 32

        let outputs = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for index in 0..<count {
                group.addTask {
                    let bytes = Data("publication-\(index)".utf8)
                    let output = try OutputWriter.write(beside: input, extension: "bin") { stage in
                        try bytes.write(to: stage)
                    }
                    return (index, output)
                }
            }
            var results: [(Int, URL)] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(outputs.count, count)
        XCTAssertEqual(Set(outputs.map { $0.1 }).count, count)
        for (index, output) in outputs {
            XCTAssertEqual(try Data(contentsOf: output), Data("publication-\(index)".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: collision), sentinel)
        XCTAssertEqual(try Data(contentsOf: input), Data("source sentinel".utf8))
        XCTAssertEqual(try names().count, count + 2)
        try assertNoStages()
    }

    func testThrowingBodyRemovesItsPartialStage() throws {
        let input = try write("throwing.source", data: Data("source".utf8))

        XCTAssertThrowsError(try OutputWriter.write(beside: input, extension: "bin") { stage in
            try Data("partial output".utf8).write(to: stage)
            throw FixtureError.expected
        }) { error in
            guard case FixtureError.expected = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(try names(), ["throwing.source"])
        try assertNoStages()
    }

    func testCancellationBeforePublicationRemovesItsStageAndPreservesSource() async throws {
        let input = try write("cancelled.source", data: Data("source".utf8))
        let worker = Task.detached {
            try OutputWriter.write(beside: input, extension: "bin") { stage in
                try Data("complete staged output".utf8).write(to: stage)
                // Cancel this worker deterministically after staging, before publication.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            _ = try await worker.value
            XCTFail("A cancelled writer must not publish its staged file.")
        } catch is CancellationError {
            // Expected: the writer observes cancellation after the body returns.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try names(), ["cancelled.source"])
        XCTAssertEqual(try Data(contentsOf: input), Data("source".utf8))
        try assertNoStages()
    }

    func testBrokenSymlinkCollisionIsPreservedAndSkipped() throws {
        let input = try write("report.source", data: Data("source".utf8))
        let collision = directory.appendingPathComponent("report.bin")
        let missingTarget = directory.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: collision, withDestinationURL: missingTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: collision.path))

        let output = try OutputWriter.write(beside: input, extension: "bin") { stage in
            try Data("published".utf8).write(to: stage)
        }

        XCTAssertEqual(output.lastPathComponent, "report 1.bin")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: collision.path), missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(try Data(contentsOf: output), Data("published".utf8))
        try assertNoStages()
    }

    func testEmptyOutputIsRejectedAndStageIsRemoved() throws {
        let input = try write("empty.source", data: Data("source".utf8))

        XCTAssertThrowsError(try OutputWriter.write(beside: input, extension: "bin") { stage in
            try Data().write(to: stage)
        }) { error in
            guard case OrangeError.conversionFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(try names(), ["empty.source"])
        try assertNoStages()
    }

    private func write(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func assertNoStages(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try names().contains { $0.hasPrefix(".orange-") }, file: file, line: line)
    }
}
