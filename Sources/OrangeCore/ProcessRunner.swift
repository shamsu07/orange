import Foundation
import Darwin

/// Runs an executable directly, without a shell, while draining both output pipes.
public enum ProcessRunner {
    public static func executable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        var overridePaths: [String] = []
        if let override = ProcessInfo.processInfo.environment["ORANGE_BACKEND_DIR"], override.hasPrefix("/") {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &directory), directory.boolValue {
                overridePaths = [override, URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("bin").path]
            }
        }
        var bundled: [String] = []
        if let resources = Bundle.main.resourceURL {
            bundled = [resources.appendingPathComponent("Tools/bin", isDirectory: true).path,
                       resources.appendingPathComponent("Tools", isDirectory: true).path]
        }
        let paths = overridePaths + bundled + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for path in paths where path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory),
               !directory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func run(_ executable: URL, arguments: [String], currentDirectory: URL? = nil, timeout: TimeInterval? = nil) throws -> String {
        try Task.checkCancellation()
        if let timeout, !timeout.isFinite || timeout <= 0 { throw OrangeError.invalidInput("A process timeout must be a positive, finite number of seconds.") }
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OrangeError.backendMissing("The executable is unavailable: \(executable.lastPathComponent).")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = BoundedProcessOutput(), err = BoundedProcessOutput()
        let readers = DispatchGroup()
        do { try process.run() }
        catch { throw OrangeError.conversionFailed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)") }
        for (pipe, destination) in [(stdout, out), (stderr, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                while true {
                    do {
                        guard let data = try pipe.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty else { break }
                        destination.append(data)
                    } catch { break }
                }
            }
        }
        var cancelled = false, timedOut = false
        let started = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            let exceededTimeout = timeout.map { ProcessInfo.processInfo.systemUptime - started >= $0 } ?? false
            if Task.isCancelled || exceededTimeout {
                cancelled = Task.isCancelled
                timedOut = exceededTimeout
                process.terminate()
                // A backend that ignores SIGTERM must not keep a cancelled conversion alive.
                let deadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        // Close the parent's write ends so the readers always observe EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        readers.wait()
        if cancelled || Task.isCancelled { throw OrangeError.cancelled }
        if timedOut { throw OrangeError.conversionFailed("\(executable.lastPathComponent) exceeded its \(String(format: "%g", timeout ?? 0))-second time limit. The process was stopped.") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = err.string.isEmpty ? out.string : err.string
            throw OrangeError.conversionFailed("\(executable.lastPathComponent) failed (exit \(process.terminationStatus)). \(String(detail.suffix(12_000)))")
        }
        return out.string
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 262_144
    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
