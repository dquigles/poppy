import Foundation

/// Poppy or Poppy Dev (DESIGN §12.1): `./scripts/bundle.sh` builds the dev copy, which runs
/// beside the installed Poppy with its own bundle ID, executable name (`poppy-dev`) and
/// settings folder, no hotkey by default, and a DEV tag on the pill. `POPPY_DEV=1` makes an
/// unbundled `swift run` a dev copy too.
nonisolated enum AppVariant {
    static let isDev: Bool = {
        if (Bundle.main.object(forInfoDictionaryKey: "PoppyDev") as? Bool) == true { return true }
        return ProcessInfo.processInfo.environment["POPPY_DEV"] == "1"
    }()

    /// "Poppy" or "Poppy Dev", in the menu, the menu bar tooltip and the log.
    static var name: String { isDev ? "Poppy Dev" : "Poppy" }
}
