import Foundation

/// Discoverable entry points. Data rows keep their own identity and aren't branded as apps.
public enum CoreCommand: String, CaseIterable, Hashable {
    case define, translate, caffeinate, emoji, notes, clipboard, shortcuts, agents, ai, talk, confetti, wifi, bluetooth, audio, newSnippet, newQuicklink
    public var title: String {
        switch self {
        case .ai: return "AI Chat"
        case .talk: return "Dictate Text"
        case .confetti: return "Throw Confetti"
        case .shortcuts: return "Apple Shortcuts"
        case .define: return "Define Word"
        case .translate: return "Translate Text"
        case .caffeinate: return "Caffeinate"
        case .emoji: return "Search Emoji"
        case .notes: return "Open Notes"
        case .clipboard: return "Clipboard History"
        case .agents: return "Open Agents"
        case .wifi: return "Wi-Fi Networks"
        case .bluetooth: return "Bluetooth Devices"
        case .audio: return "Audio Devices"
        case .newSnippet: return "Create Snippet"
        case .newQuicklink: return "Create Quicklink"
        }
    }
    public var query: String {
        switch self {
        case .emoji: return ":"
        case .clipboard: return "clip"
        case .newSnippet: return "new snippet"
        case .newQuicklink: return "new quicklink"
        default: return rawValue
        }
    }
    public var symbol: String {
        switch self {
        case .ai: return "bubble.left.and.bubble.right"
        case .talk: return "mic"
        case .confetti: return "party.popper"
        case .shortcuts: return "square.stack.3d.up"
        case .define: return "book.closed"
        case .translate: return "character.bubble"
        case .caffeinate: return "cup.and.saucer"
        case .emoji: return "face.smiling"
        case .notes: return "note.text"
        case .clipboard: return "doc.on.clipboard"
        case .agents: return "terminal"
        case .wifi: return "wifi"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .audio: return "speaker.wave.2"
        case .newSnippet: return "text.badge.plus"
        case .newQuicklink: return "link.badge.plus"
        }
    }
    public var detail: String {
        switch self {
        case .shortcuts: return "Find and run your Apple Shortcuts"
        case .define: return "Look up words in your Mac’s dictionaries"
        case .translate: return "Translate between languages on your Mac"
        case .caffeinate: return "Keep your Mac awake"
        case .emoji: return "Browse emoji and copy one"
        case .newSnippet: return "Save text to copy by keyword"
        case .newQuicklink: return "Save a link to open by name"
        default: return "Built into Volant"
        }
    }
    /// Extra words a command answers to besides its title and raw value.
    var searchTerms: String {
        switch self {
        case .ai: return "acp"
        case .newSnippet: return LauncherRouting.snippetCreatePhrases.sorted().joined(separator: " | ")
        case .newQuicklink: return LauncherRouting.quicklinkCreatePhrases.sorted().joined(separator: " | ") + " | new link"
        default: return ""
        }
    }

    public static func search(_ query: String) -> [Self] {
        allCases.filter { ($0.title + " " + $0.rawValue + " " + $0.searchTerms).localizedCaseInsensitiveContains(query) }
    }
}
