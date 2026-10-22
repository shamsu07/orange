import AppKit
import OrangeCore

enum WheelAppearance: String, CaseIterable { case glass = "Glass", solid = "Solid" }

enum DragShortcut: String, CaseIterable, Identifiable {
    case shift, command, control, option, optionShift, commandShift, controlShift, optionCommand
    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .optionShift: return [.option, .shift]
        case .commandShift: return [.command, .shift]
        case .controlShift: return [.control, .shift]
        case .optionCommand: return [.option, .command]
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"; case .command: return "⌘"; case .control: return "⌃"; case .option: return "⌥"
        case .optionShift: return "⌥⇧"; case .commandShift: return "⌘⇧"; case .controlShift: return "⌃⇧"; case .optionCommand: return "⌥⌘"
        }
    }
    var label: String {
        switch self {
        case .shift: return "⇧  Shift"; case .command: return "⌘  Command"; case .control: return "⌃  Control"; case .option: return "⌥  Option"
        case .optionShift: return "⌥⇧  Option + Shift"; case .commandShift: return "⌘⇧  Command + Shift"
        case .controlShift: return "⌃⇧  Control + Shift"; case .optionCommand: return "⌥⌘  Option + Command"
        }
    }
}

enum WheelMode: String, CaseIterable {
    case convert = "Convert", tools = "Tools", actions = "Actions"
    var symbol: String { switch self { case .convert: return "arrow.triangle.2.circlepath"; case .tools: return "slider.horizontal.3"; case .actions: return "cursorarrow.and.square.on.square.dashed" } }
    var shortcut: String { switch self { case .convert: return "⇧"; case .tools: return "⌘"; case .actions: return "⌃" } }
}

enum WheelChoice: Hashable, Identifiable {
    case format(OutputFormat), tool(ToolKind), action(FileAction)
    var id: String { label }
    var label: String {
        switch self { case .format(let format): return format == .jpeg ? "JPG" : format.label; case .tool(let tool): return tool.label; case .action(let action): return action.label }
    }
    var symbol: String {
        switch self { case .format: return "doc"; case .tool(let tool): return tool.symbol; case .action(let action): return action.symbol }
    }
    var operation: ConversionOperation? {
        switch self { case .format(let format): return .convert(format); case .tool(let tool): return .tool(tool); case .action: return nil }
    }
}

struct ConversionJob: Identifiable {
    enum State { case queued, running, complete, failed, cancelled }
    let id: UUID
    let inputs: [URL]
    let operation: ConversionOperation
    var state: State = .queued
    var outputs: [URL] = []
    var message: String?
    var started: Date?
    var elapsed: TimeInterval?
}
