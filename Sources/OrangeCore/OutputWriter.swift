import Foundation
import Darwin

/// Stages alongside the destination, then publishes without replacing an existing file.
public enum OutputWriter {
    public static func write(beside input: URL, extension ext: String, suffix: String = "", body: (URL) throws -> Void) throws -> URL {
        let directory = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        let stage = directory.appendingPathComponent(".orange-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try body(stage)
        try Task.checkCancellation()
        guard let size = try? stage.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw OrangeError.conversionFailed("The converter produced no output.")
        }
        for index in 0..<10_000 {
            let number = index == 0 ? "" : " \(index)"
            let destination = directory.appendingPathComponent("\(base)\(number).\(ext)")
            // Darwin's exclusive rename also works on volumes without hard-link support.
            if renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            let code = errno
            if code == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path])
        }
        throw OrangeError.conversionFailed("Too many files with the same output name.")
    }
}
