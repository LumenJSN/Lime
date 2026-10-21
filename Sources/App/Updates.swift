import AppKit
import Sparkle

/// Sparkle updater. It checks the appcast on GitHub once a day and asks
/// before installing; "Install updates automatically" in About Lime skips
/// the question. Every update must carry Lime's EdDSA signature.
@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var available = false

    /// Starts only inside the built app, whose Info.plist holds the feed and key.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        available = true
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Lime lives in the menu bar with no Dock icon, so Sparkle would keep a
    /// scheduled update waiting in the background. Lime shows it instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    /// Brings a scheduled update's alert to the front as soon as it is found.
    /// macOS won't let a background app take focus, so the alert is only
    /// raised above other windows.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                Updates.shared.checkNow()
                for delay in [0.3, 1.0, 2.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Updates.raiseSparkleWindows() }
                }
            }
        }
    }

    /// Floats Sparkle's own windows (alert, progress) above other apps.
    private static func raiseSparkleWindows() {
        for window in NSApp.windows where window.isVisible {
            guard let owner = window.windowController.map({ String(describing: type(of: $0)) }),
                  owner.hasPrefix("SU") || owner.hasPrefix("SPU") else { continue }
            window.level = .floating
            window.orderFrontRegardless()
        }
    }
}
