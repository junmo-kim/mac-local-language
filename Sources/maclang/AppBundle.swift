import Foundation
import LangCore

/// Materializes `<home>/MacLang.app`: a copy of this executable wrapped in a bundle so that
/// LaunchServices (`open`) starts it inside the GUI login session.
enum AppBundle {
    static func currentExecutable() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    private static func stampURL(_ paths: Paths) -> URL { paths.home.appendingPathComponent("bundle-stamp") }

    private static func expectedStamp(label: String) throws -> BundleStamp {
        guard let exe = currentExecutable(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = (attrs[.modificationDate] as? Date) else {
            throw CLIError("cannot inspect the maclang executable", code: .internalError,
                           fix: "reinstall maclang (the running binary must be a readable file) and retry")
        }
        return BundleStamp(version: Version.current, label: label, size: size, mtime: Int(mtime.timeIntervalSince1970))
    }

    static func installedVersion(_ paths: Paths) -> (version: String?, label: String?) {
        guard let data = try? Data(contentsOf: paths.appBundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (plist["CFBundleShortVersionString"] as? String, plist["CFBundleIdentifier"] as? String)
    }

    /// Build or rebuild the bundle when missing, stale (version/label/executable) or unsigned-by-us.
    ///
    /// Only call this when no healthy maclang server is running from the bundle: replacing a bundle
    /// under a live process is what the callers' ordering exists to avoid. `deadline` bounds codesign.
    static func ensure(_ paths: Paths, deadline: Date = .distantFuture) throws {
        let fm = FileManager.default
        let expected = try expectedStamp(label: paths.label)
        let installed = installedVersion(paths)
        let stamp = (try? Data(contentsOf: stampURL(paths))).flatMap(BundleStamp.decode)
        if !BundleSpec.needsRebuild(bundleExists: fm.fileExists(atPath: paths.bundleExecutable.path), stamp: stamp,
                                    expected: expected, plistVersion: installed.version, plistLabel: installed.label) {
            return
        }
        guard let exe = currentExecutable() else { throw CLIError("cannot locate the maclang executable", code: .internalError,
                                                                                  fix: "run maclang by its full path, or reinstall it, then retry") }

        let tmp = paths.home.appendingPathComponent("MacLang.app.tmp-\(getpid())")
        do {
            try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            let macOS = tmp.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try BundleSpec.infoPlist(label: paths.label, version: Version.current)
                .write(to: tmp.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: exe, to: macOS.appendingPathComponent("maclang"))
        } catch {
            try? fm.removeItem(at: tmp)
            throw CLIError("cannot create the app bundle: \(error.localizedDescription)", code: .internalError,
                           fix: "check that \(paths.home.path) is writable and has free space (or set MACLANG_HOME to another directory), then retry", field: "home", received: paths.home.path)
        }
        let signTimeout = min(30, deadline.timeIntervalSinceNow)
        guard signTimeout > 0 else {
            try? fm.removeItem(at: tmp)
            throw CLIError("timed out before the app bundle could be signed", code: .timeout,
                           fix: "retry with a larger `--timeout` (signing needs a few seconds)")
        }
        let signResult = Launcher.codesign(label: paths.label, bundle: tmp, timeout: signTimeout)
        guard let signed = signResult, signed.status == 0 else {
            try? fm.removeItem(at: tmp)
            throw CLIError("codesign failed for the app bundle: \((signResult?.text ?? "no output").trimmingCharacters(in: .whitespacesAndNewlines))", code: .internalError,
                           fix: "check that /usr/bin/codesign works (`xcode-select -p`), then retry the command")
        }
        do {
            if fm.fileExists(atPath: paths.appBundle.path) {
                _ = try fm.replaceItemAt(paths.appBundle, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: paths.appBundle)
            }
            try expected.encode().write(to: stampURL(paths), options: .atomic)
        } catch {
            try? fm.removeItem(at: tmp)
            throw CLIError("cannot install the app bundle: \(error.localizedDescription)", code: .internalError,
                           fix: "check that \(paths.home.path) is writable, then retry", field: "home", received: paths.home.path)
        }
    }
}
