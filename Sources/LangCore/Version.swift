import Foundation

public enum Version {
    public static let current = "0.1.0"

    /// Printed to stderr when the running server's version differs from the CLI's.
    public static func mismatchWarning(server: String, cli: String) -> String? {
        guard server != cli else { return nil }
        return "warning: server \(server) differs from CLI \(cli); run 'maclang service stop && maclang service start'"
    }
}
