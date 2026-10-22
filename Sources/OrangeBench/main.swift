import CoreGraphics
import CoreFoundation
import Darwin
import Foundation
import ImageIO
import OrangeCore
import UniformTypeIdentifiers

private enum BenchmarkError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private let warmupCount = 3
private let iterationCount = 15
private let imageWidth = 3840
private let imageHeight = 2160

private func fail(_ message: String) -> BenchmarkError { .invalid(message) }

private enum ExecutionMode: String { case main, detached }
private struct BenchmarkOptions {
    var outputArgument: String?
    var execution: ExecutionMode = .main
    var trimAllocator = false
}
private let usageText = "Usage: OrangeBench [--output <new JSON file inside this workspace>] [--execution main|detached] [--trim-allocator]"

/// Validate lexical containment before inspecting any path, then reject symlink ancestors.
private func validatedOutput(_ argument: String, workspace: URL) throws -> URL {
    let candidate = URL(fileURLWithPath: argument, relativeTo: workspace).standardizedFileURL
    let root = workspace.standardizedFileURL.path
    guard candidate.path.hasPrefix(root + "/") else {
        throw fail("--output must be a file inside the current Orange workspace.")
    }
    let relative = String(candidate.path.dropFirst(root.count + 1))
    var componentURL = workspace
    for component in relative.split(separator: "/") {
        componentURL.appendPathComponent(String(component))
        var information = stat()
        if lstat(componentURL.path, &information) == 0 {
            guard information.st_mode & S_IFMT != S_IFLNK else {
                throw fail("--output cannot contain symbolic links.")
            }
        } else if errno == ENOENT {
            // Descendants cannot exist if this ancestor does not exist.
            break
        } else {
            throw fail("The output path could not be inspected: \(componentURL.lastPathComponent).")
        }
    }
    return candidate
}

private func parseOptions() throws -> BenchmarkOptions {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var options = BenchmarkOptions()
    var index = 0
    var sawExecution = false
    while index < arguments.count {
        if arguments[index] == "--trim-allocator", !options.trimAllocator {
            options.trimAllocator = true
            index += 1
            continue
        }
        guard index + 1 < arguments.count else {
            throw fail(usageText)
        }
        let value = arguments[index + 1]
        switch arguments[index] {
        case "--output" where options.outputArgument == nil && !value.isEmpty:
            options.outputArgument = value
        case "--execution" where !sawExecution:
            guard let execution = ExecutionMode(rawValue: value) else {
                throw fail("--execution must be main or detached.")
            }
            options.execution = execution
            sawExecution = true
        default:
            throw fail(usageText)
        }
        index += 2
    }
    return options
}

private func makeFixture(at url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: imageWidth, height: imageHeight,
                                  bitsPerComponent: 8, bytesPerRow: imageWidth * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw fail("The synthetic image context could not be allocated.")
    }
    let colors = [CGColor(red: 0.98, green: 0.22, blue: 0.05, alpha: 1),
                  CGColor(red: 0.1, green: 0.55, blue: 0.88, alpha: 1),
                  CGColor(red: 0.06, green: 0.12, blue: 0.2, alpha: 1)]
    guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.55, 1]) else {
        throw fail("The synthetic gradient could not be created.")
    }
    context.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: imageWidth, y: imageHeight), options: [])
    for row in 0..<12 {
        for column in 0..<20 {
            let red = CGFloat((column * 37 + row * 13) % 101) / 100
            let blue = CGFloat((column * 17 + row * 43) % 101) / 100
            context.setFillColor(CGColor(red: red, green: 0.6, blue: blue, alpha: 0.65))
            context.fillEllipse(in: CGRect(x: column * 192 + 24, y: row * 180 + 20, width: 125, height: 125))
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw fail("The synthetic PNG writer could not be opened.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw fail("The synthetic PNG could not be written.") }
}

private func byteCount(_ url: URL) throws -> Int {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw fail("A file size could not be measured.")
    }
    return size
}

private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func peakRSSBytes() throws -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw fail("Process peak memory could not be measured.") }
    return Int64(usage.ru_maxrss)
}

private func currentRSSBytes() -> UInt64? {
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { words in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), words, &count)
        }
    }
    return status == KERN_SUCCESS ? UInt64(information.resident_size) : nil
}

private func physicalFootprintBytes() -> UInt64? {
    var information = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { words in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
        }
    }
    return status == KERN_SUCCESS ? UInt64(information.phys_footprint) : nil
}

private struct MemorySnapshot {
    let currentRSS: UInt64?
    let physicalFootprint: UInt64?
    let peakRSS: Int64

    var json: [String: Any] {
        var result: [String: Any] = ["peak_rss_bytes": peakRSS]
        if let currentRSS { result["current_rss_bytes"] = currentRSS }
        else { result["current_rss_bytes"] = NSNull() }
        if let physicalFootprint { result["physical_footprint_bytes"] = physicalFootprint }
        else { result["physical_footprint_bytes"] = NSNull() }
        return result
    }
}

private func memorySnapshot() throws -> MemorySnapshot {
    MemorySnapshot(currentRSS: currentRSSBytes(), physicalFootprint: physicalFootprintBytes(), peakRSS: try peakRSSBytes())
}

/// Opt-in diagnostic only. The application does not invoke allocator pressure
/// relief after jobs, and normal benchmark runs must retain that same behavior.
private func allocatorRelief(enabled: Bool) throws -> [String: Any]? {
    guard enabled else { return nil }
    let start = DispatchTime.now().uptimeNanoseconds
    let released = malloc_zone_pressure_relief(nil, 0)
    let duration = milliseconds(since: start)
    return ["allocator_reported_released_bytes": released, "duration_ms": duration,
            "memory_after_relief": try memorySnapshot().json]
}

private func measure(name: String, trimAllocator: Bool, operation: () throws -> ConversionResult) throws -> [String: Any] {
    let phaseStart = try memorySnapshot()
    var warmupMemory: [[String: Any]] = []
    for index in 0..<warmupCount {
        let before = try memorySnapshot()
        let result = try autoreleasepool { try operation() }
        let afterConversion = try memorySnapshot()
        let relief = try allocatorRelief(enabled: trimAllocator)
        for output in result.outputs { try FileManager.default.removeItem(at: output) }
        let afterCleanup = try memorySnapshot()
        var memory: [String: Any] = ["iteration": index + 1, "before": before.json,
                                     "after_conversion_and_pool_drain": afterConversion.json,
                                     "after_output_cleanup": afterCleanup.json]
        if let relief { memory["allocator_pressure_relief"] = relief }
        warmupMemory.append(memory)
    }
    var samples: [Double] = []
    var sizes: [Int] = []
    var iterationMemory: [[String: Any]] = []
    for index in 0..<iterationCount {
        let before = try memorySnapshot()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try autoreleasepool { try operation() }
        let duration = milliseconds(since: start)
        let afterConversion = try memorySnapshot()
        let relief = try allocatorRelief(enabled: trimAllocator)
        guard result.outputs.count == 1, let output = result.outputs.first else {
            throw fail("The benchmark expected exactly one output per conversion.")
        }
        samples.append(duration)
        sizes.append(try byteCount(output))
        try FileManager.default.removeItem(at: output)
        let afterCleanup = try memorySnapshot()
        var memory: [String: Any] = ["iteration": index + 1, "duration_ms": duration,
                                     "before": before.json,
                                     "after_conversion_and_pool_drain": afterConversion.json,
                                     "after_output_cleanup": afterCleanup.json]
        if let relief { memory["allocator_pressure_relief"] = relief }
        iterationMemory.append(memory)
    }
    let phaseEnd = try memorySnapshot()
    let sorted = samples.sorted()
    let percentileIndex = min(sorted.count - 1, max(0, Int(ceil(0.95 * Double(sorted.count))) - 1))
    return ["operation": name, "warmup_iterations": warmupCount, "measured_iterations": iterationCount,
            "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[percentileIndex],
            "percentile_method": "nearest_rank", "samples_ms": samples,
            "output_bytes_each_iteration": sizes,
            "memory_at_phase_start": phaseStart.json, "memory_at_phase_end": phaseEnd.json,
            "warmup_memory": warmupMemory, "iteration_memory": iterationMemory,
            "timing_scope": "conversion call including decode, encode and atomic output publication; excludes fixture generation, file-size lookup, memory sampling, optional allocator pressure relief and output deletion"]
}

private func run(options: BenchmarkOptions) throws {
    let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path),
          FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Sources/OrangeCore").path) else {
        throw fail("Run OrangeBench from the Orange repository root; generated fixtures stay inside it.")
    }
    let output = try options.outputArgument.map { try validatedOutput($0, workspace: workspace) }
    if let output, FileManager.default.fileExists(atPath: output.path) {
        throw fail("The requested report already exists. Choose a new --output filename.")
    }
    let directory = workspace.appendingPathComponent(".cache/benchmarks/\(UUID().uuidString)", isDirectory: true)
    // Prevent an existing .cache or benchmarks symlink from redirecting fixture writes.
    _ = try validatedOutput(directory.appendingPathComponent("fixture.png").path, workspace: workspace)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("synthetic-4k.png")
    let fixtureStartMemory = try memorySnapshot()
    try autoreleasepool { try makeFixture(at: input) }
    let sourceBytes = try byteCount(input)
    let fixtureEndMemory = try memorySnapshot()
    var jpegSettings = ConversionSettings()
    jpegSettings.quality = 0.82
    var resizeSettings = ConversionSettings()
    resizeSettings.maxDimension = 1920

    let jpeg = try measure(name: "PNG_to_JPEG_quality_0.82", trimAllocator: options.trimAllocator) {
        try ImageConverter.convert(input, to: .jpeg, settings: jpegSettings)
    }
    let jpegPeakRSS = try peakRSSBytes()
    let resize = try measure(name: "PNG_resize_long_edge_1920", trimAllocator: options.trimAllocator) {
        try ImageConverter.apply(.resize, to: input, settings: resizeSettings)
    }
    let resizePeakRSS = try peakRSSBytes()
    let queryStartMemory = try memorySnapshot()
    _ = autoreleasepool { ImageConverter.formats(for: input) }
    let queryCount = 100
    let queryStart = DispatchTime.now().uptimeNanoseconds
    var formats: [OutputFormat] = []
    // A command-line executable has no AppKit event loop draining autoreleases.
    // Match an individual selection-probing job instead of retaining ImageIO's
    // temporary Objective-C objects across all 100 queries.
    for _ in 0..<queryCount { formats = autoreleasepool { ImageConverter.formats(for: input) } }
    let queryDuration = milliseconds(since: queryStart)
    guard !formats.isEmpty else { throw fail("The generated image has no available conversion formats.") }

    let queryEndMemory = try memorySnapshot()
    let process = ProcessInfo.processInfo
    #if DEBUG
    let debugDefinition = true
    #else
    let debugDefinition = false
    #endif
    let report: [String: Any] = [
        "schema_version": 1,
        "harness_revision": 5,
        "benchmark": "Orange synthetic image conversion smoke measurement",
        "measured_at_utc": ISO8601DateFormatter().string(from: Date()),
        "execution": ["mode": options.execution.rawValue,
                      "workload_on_main_thread": Thread.isMainThread,
                      "main_run_loop_pumped": options.execution == .detached,
                      "scope": options.execution == .detached
                        ? "Same sequential workload in one Task.detached with the main CFRunLoop running; each conversion retains its own autorelease pool. This isolates thread/run-loop effects, not the application's full per-job task lifecycle."
                        : "Original baseline: sequential workload on the main thread without pumping its run loop; each conversion has its own autorelease pool."],
        "allocator_pressure_relief": ["enabled": options.trimAllocator,
                                     "performance_results_are_allocator_diagnostic": options.trimAllocator,
                                     "scope": "Disabled by default. When enabled, malloc_zone_pressure_relief(nil, 0) runs after each conversion pool drains and before output deletion; its duration is recorded separately. This does not reproduce the application's normal allocation behavior or reset process peak RSS."],
        "environment": ["operating_system": process.operatingSystemVersionString,
                        "logical_cpu_count": process.processorCount,
                        "active_logical_cpu_count": process.activeProcessorCount,
                        "debug_compilation_condition_defined": debugDefinition],
        "fixture": ["width_px": imageWidth, "height_px": imageHeight, "source_format": "PNG",
                    "source_bytes": sourceBytes, "description": "Deterministic RGB gradient with a grid of colored ellipses",
                    "memory_at_phase_start": fixtureStartMemory.json, "memory_at_phase_end": fixtureEndMemory.json],
        "measurements": [jpeg, resize],
        "warm_capability_query": ["iterations": queryCount, "total_ms": queryDuration,
                                  "mean_ms": queryDuration / Double(queryCount),
                                  "formats": formats.map(\.rawValue),
                                  "memory_at_phase_start": queryStartMemory.json,
                                  "memory_at_phase_end": queryEndMemory.json,
                                  "scope": "ImageConverter.formats after one warmup; source/metadata opening and per-query autorelease-pool drain included, no full pixel decode requested"],
        "process_peak_rss_bytes": queryEndMemory.peakRSS,
        "peak_rss_scope": "Entire benchmark process, including fixture generation, warmups, conversions and capability queries; Darwin ru_maxrss is bytes",
        "phase_peak_rss_bytes": ["after_fixture_generation": fixtureEndMemory.peakRSS,
                                 "after_JPEG_warmups_and_measurements": jpegPeakRSS,
                                 "after_resize_warmups_and_measurements": resizePeakRSS,
                                 "after_capability_queries": queryEndMemory.peakRSS],
        "phase_peak_rss_scope": "Monotonic process high-water snapshots; not per-operation memory use. The peak is never reset or reduced by subtracting earlier phases.",
        "current_rss_scope": "Mach MACH_TASK_BASIC_INFO resident_size snapshots in bytes, sampled outside conversion timing. Null means the Mach query was unavailable. Current RSS includes allocator and system caches; it does not by itself establish a leak.",
        "physical_footprint_scope": "Mach TASK_VM_INFO phys_footprint snapshots in bytes, alongside RSS and never subtracted from it. Null means this Mach query was unavailable. The allocator-relief diagnostic must be compared separately from default execution.",
        "caveats": ["Synthetic input is not representative photographic content.",
                    "This is a measurement smoke run, not a comparison with Tangerine or a performance guarantee.",
                    "Fifteen measured samples make nearest-rank p95 equal to the slowest sample.",
                    "Results depend on build optimization, machine load, OS encoders and filesystem cache state."]
    ]
    var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    if let output {
        // Revalidate before writing, and create exclusively so a pre-existing report is never replaced.
        let destination = try validatedOutput(output.path, workspace: workspace)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try validatedOutput(destination.path, workspace: workspace)
        try data.write(to: destination, options: .withoutOverwriting)
    }
    FileHandle.standardOutput.write(data)
}

/// An explicit diagnostic comparison, not a memory workaround: the application
/// converts on detached workers while its main event loop remains responsive.
/// This comparison keeps the whole workload in one worker to isolate execution
/// context; it does not reproduce every application task boundary.
private func runDetached(options: BenchmarkOptions) throws {
    let loop = CFRunLoopGetMain()
    var context = CFRunLoopSourceContext()
    context.perform = { _ in }
    guard let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) else {
        throw fail("The diagnostic main-run-loop source could not be created.")
    }
    CFRunLoopAddSource(loop, keepAlive, CFRunLoopMode.defaultMode)
    defer { CFRunLoopRemoveSource(loop, keepAlive, CFRunLoopMode.defaultMode) }
    let worker = Task.detached(priority: .userInitiated) {
        let failure: String?
        do { try run(options: options); failure = nil }
        catch { failure = error.localizedDescription }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            if let failure {
                FileHandle.standardError.write(Data("OrangeBench: \(failure)\n".utf8))
                exit(1)
            }
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }
    withExtendedLifetime(worker) { CFRunLoopRun() }
}

do {
    let options = try parseOptions()
    if options.execution == .detached { try runDetached(options: options) }
    else { try run(options: options) }
} catch {
    FileHandle.standardError.write(Data("OrangeBench: \(error.localizedDescription)\n".utf8))
    exit(1)
}
