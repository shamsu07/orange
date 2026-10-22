import Foundation

/// Available only in an explicitly marked debug bundle. Records event metadata,
/// never file paths, clipboard contents or typed text. Release bundles return nil.
@MainActor final class WheelActivationTrace {
    private let sink: WheelTraceSink
    private let uptime: @MainActor () -> TimeInterval
    private let runID = UUID().uuidString
    private var ordinal = 0
    private var lastSample: [String: TimeInterval] = [:]

    static func makeIfEnabled() -> WheelActivationTrace? {
        #if DEBUG
        guard Bundle.main.object(forInfoDictionaryKey: "OrangeWheelTrace") as? Bool == true else { return nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try? WheelActivationTrace(url: root.appendingPathComponent(".cache/wheel-activation.jsonl"))
        #else
        return nil
        #endif
    }

    init(url: URL, uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        sink = try WheelTraceSink(url: url)
        self.uptime = uptime
    }

    func record(_ event: String, fields: @autoclosure () -> [String: Any] = [:], sample: String? = nil) {
        let now = uptime()
        if let sample {
            if let previous = lastSample[sample], now - previous < 0.025 { return }
            lastSample[sample] = now
        }
        ordinal += 1
        var record = fields()
        record["event"] = event
        record["ordinal"] = ordinal
        record["receivedUptime"] = now
        record["run"] = runID
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        sink.append(data)
    }

    func flush() async { await sink.flush() }
}

/// File ownership is confined to one serial queue. Captured Data is immutable.
private final class WheelTraceSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.orange.wheel-trace", qos: .utility)
    private let handle: FileHandle

    init(url: URL) throws {
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        queue.async { [self] in try? handle.write(contentsOf: data) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? handle.synchronize()
                continuation.resume()
            }
        }
    }

    deinit { try? handle.close() }
}
