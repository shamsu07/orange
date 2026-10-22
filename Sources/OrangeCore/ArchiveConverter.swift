import Foundation

/// Creates archives without extracting or executing any archived content.
public enum ArchiveConverter {
    public static func formats(for input: URL) -> [OutputFormat] {
        let family = FileFamily.detect(input)
        if family == .archive { return [] }
        return family == .folder ? [.zip, .tar] : [.zip, .tar, .gzip]
    }

    public static func convert(_ input: URL, to format: OutputFormat, settings: ConversionSettings) throws -> ConversionResult {
        guard FileFamily.detect(input) != .archive else {
            throw OrangeError.unsupported("Archive transcoding requires extraction and is unavailable. Orange can create ZIP, TAR, and single-file GZIP archives.")
        }
        return try create([input], to: format)
    }

    public static func create(_ inputs: [URL], to format: OutputFormat) throws -> ConversionResult {
        guard let first = inputs.first else { throw OrangeError.invalidInput("Select at least one file or folder to archive.") }
        guard [.zip, .tar, .gzip].contains(format) else {
            throw OrangeError.unsupported("Archive creation supports ZIP, TAR, and single-file GZIP.")
        }
        try Task.checkCancellation()
        for input in inputs {
            guard input.isFileURL, (try? input.checkResourceIsReachable()) == true else {
                throw OrangeError.invalidInput("An archive source is missing or unreadable.")
            }
        }
        if format == .gzip { return try createGZIP(first, inputs: inputs) }
        let directory = first.deletingLastPathComponent().standardizedFileURL
        guard inputs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory }) else {
            throw OrangeError.unsupported("Files in one archive must share a parent folder. Place the selected items in the same folder first.")
        }
        let names = inputs.map(\.lastPathComponent)
        guard Set(names).count == names.count else { throw OrangeError.invalidInput("The same archive source was selected more than once.") }
        // Prefixing every name prevents a filename beginning with '-' from becoming an option.
        let relativeNames = names.map { "./" + $0 }
        let name = format == .zip ? "zip" : "tar"
        guard let executable = ProcessRunner.executable(named: name) else {
            throw OrangeError.backendMissing("The macOS \(name) archive utility is unavailable.")
        }
        let output = try OutputWriter.write(beside: first, extension: format.fileExtension,
                                            suffix: inputs.count > 1 ? "-archive" : "") { stage in
            if format == .zip {
                // -y stores symlinks as links, so directories cannot pull in linked external trees.
                _ = try ProcessRunner.run(executable, arguments: ["-q", "-r", "-y", stage.path, "--"] + relativeNames,
                                          currentDirectory: directory)
                _ = try ProcessRunner.run(executable, arguments: ["-T", stage.path], currentDirectory: directory)
            } else {
                // bsdtar stores symlinks without following them unless explicitly asked to do so.
                _ = try ProcessRunner.run(executable, arguments: ["-cf", stage.path, "--"] + relativeNames,
                                          currentDirectory: directory)
                _ = try ProcessRunner.run(executable, arguments: ["-tf", stage.path], currentDirectory: directory)
            }
        }
        return ConversionResult(outputs: [output], message: "Created a \(format.label) archive containing \(inputs.count) selected item\(inputs.count == 1 ? "" : "s").")
    }

    private static func createGZIP(_ first: URL, inputs: [URL]) throws -> ConversionResult {
        guard inputs.count == 1, FileFamily.detect(first) != .folder else {
            throw OrangeError.unsupported("GZIP compresses one regular file. Use ZIP or TAR for folders and multiple files.")
        }
        let values = try first.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OrangeError.unsupported("GZIP requires a regular file, not a symbolic link.")
        }
        guard let executable = ProcessRunner.executable(named: "gzip") else {
            throw OrangeError.backendMissing("The macOS gzip utility is unavailable.")
        }
        // gzip's file-output mode avoids buffering binary output or changing the original source.
        let output = try OutputWriter.write(beside: first, extension: "gz") { stage in
            let sourceCopy = stage.deletingPathExtension()
            defer { try? FileManager.default.removeItem(at: sourceCopy) }
            try FileManager.default.copyItem(at: first, to: sourceCopy)
            _ = try ProcessRunner.run(executable, arguments: ["-n", "--", sourceCopy.path],
                                      currentDirectory: first.deletingLastPathComponent())
            _ = try ProcessRunner.run(executable, arguments: ["-t", "--", stage.path],
                                      currentDirectory: first.deletingLastPathComponent())
        }
        return ConversionResult(outputs: [output], message: "Created a GZIP copy. The source file was preserved.")
    }
}
