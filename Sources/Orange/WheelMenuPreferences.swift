import Foundation
import OrangeCore

struct WheelMenuPreferences: Codable, Equatable {
    var hiddenTools: [String: Set<String>] = [:]
    var hiddenActions: Set<String> = []

    static let families: [FileFamily] = [.image, .video, .audio, .pdf]
    static func tools(for family: FileFamily) -> [ToolKind] {
        switch family {
        case .image: return [.resize, .crop, .rotate, .compress, .stripMetadata, .extractText, .qrCode]
        case .video: return [.snapshot, .trim, .changeSpeed, .compress, .extractAudio, .normalizeAudio, .stripMetadata]
        case .audio: return [.trim, .changeSpeed, .compress, .normalizeAudio, .stripMetadata]
        case .pdf: return [.splitPDF, .mergePDF, .compress, .extractText, .stripMetadata]
        default: return []
        }
    }
    func isEnabled(_ tool: ToolKind, for family: FileFamily) -> Bool {
        !(hiddenTools[family.rawValue]?.contains(tool.rawValue) ?? false)
    }
    func isEnabled(_ action: FileAction) -> Bool { !hiddenActions.contains(action.rawValue) }
    mutating func setEnabled(_ enabled: Bool, tool: ToolKind, family: FileFamily) {
        if enabled { hiddenTools[family.rawValue]?.remove(tool.rawValue) }
        else { hiddenTools[family.rawValue, default: []].insert(tool.rawValue) }
    }
    mutating func setEnabled(_ enabled: Bool, action: FileAction) {
        if enabled { hiddenActions.remove(action.rawValue) }
        else { hiddenActions.insert(action.rawValue) }
    }
}
