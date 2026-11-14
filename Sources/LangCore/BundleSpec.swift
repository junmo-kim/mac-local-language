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

/// What the materialized bundle was built from (kept next to the bundle, outside its signature).
public struct BundleStamp: Equatable, Sendable {
    public var version: String
    public var label: String
    public var size: Int
    public var mtime: Int

    public init(version: String, label: String, size: Int, mtime: Int) {
        self.version = version
        self.label = label
        self.size = size
        self.mtime = mtime
    }

    public func encode() -> Data {
        let obj: [String: Any] = ["version": version, "label": label, "size": size, "mtime": mtime]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func decode(_ data: Data) -> BundleStamp? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = o["version"] as? String, let l = o["label"] as? String,
              let s = o["size"] as? Int, let m = o["mtime"] as? Int else { return nil }
        return BundleStamp(version: v, label: l, size: s, mtime: m)
    }
}

extension BundleSpec {
    /// True when the bundle is missing, was built for another version/label, or from a different
    /// executable (size or mtime changed).
    public static func needsRebuild(bundleExists: Bool, stamp: BundleStamp?, expected: BundleStamp,
                                    plistVersion: String?, plistLabel: String?) -> Bool {
        guard bundleExists, let stamp else { return true }
        return stamp != expected || plistVersion != expected.version || plistLabel != expected.label
    }
}
