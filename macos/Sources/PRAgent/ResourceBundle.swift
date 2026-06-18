import Foundation

/// Reliable accessor for the SwiftPM resource bundle inside a hand-assembled .app.
///
/// SwiftPM's generated `Bundle.module` only checks `<.app>/PRAgent_PRAgent.bundle`
/// and a hardcoded `.build/.../debug` path, then `fatalError`s. In a wrapped .app
/// the bundle actually lives in `Contents/Resources/`, so `Bundle.module` would
/// crash on any machine that lacks the original build directory (i.e. everywhere
/// but the build machine). This resolves the real macOS locations instead and
/// returns nil — never crashes — so callers fall back to emoji / SF Symbols.
enum Res {
    static let bundle: Bundle? = {
        let name = "PRAgent_PRAgent.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),                 // Contents/Resources (where build.sh puts it)
            Bundle.main.bundleURL.appendingPathComponent(name),                    // .app root (Bundle.module's guess)
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(name),                                     // next to the binary (CLI / dev)
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }()
}
