import Foundation

public enum SessionKind: Equatable, Sendable {
    case gui
    case nonGUI(String)

    /// `launchctl managername` output (already trimmed). Exactly "Aqua" is a GUI session;
    /// anything else (including "aqua", "" and failures) is not.
    public static func parse(managerName: String) -> SessionKind {
        managerName == "Aqua" ? .gui : .nonGUI(managerName)
    }

    public var name: String {
        switch self {
        case .gui: return "Aqua"
        case .nonGUI(let raw): return raw
        }
    }
}
