import Foundation

public enum BundleSpec {
    public static let executableName = "maclang"

    /// Info.plist for the app bundle that hosts the server in a GUI login session.
    public static func infoPlist(label: String, version: String) -> Data {
        let dict: [String: Any] = [
            "CFBundleIdentifier": label,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSUIElement": true,
            "LSMinimumSystemVersion": "26.0",
        ]
        // Serializing a dictionary of plist-native values cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}
