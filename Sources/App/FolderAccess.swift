import AppKit

/// Folder access in one step. Choosing a folder in an open panel grants
/// access to it and everything inside, including Desktop, Documents and
/// Downloads, without the per-folder macOS prompts. A security-scoped
/// bookmark keeps that access after relaunch.
@MainActor
enum FolderGrants {
    private static let key = "folderBookmarks"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Paths with a saved bookmark.
    static var allowedPaths: [String] { Array(bookmarks.keys).sorted() }
    static var hasHomeAccess: Bool { bookmarks[home.path] != nil }

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Shows an open panel at `start`; the chosen folder is remembered.
    static func choose(start: URL? = nil, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.message = message
        panel.prompt = "Grant"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    /// The welcome step: one panel opened at the home folder.
    static func requestHome() -> Bool {
        choose(start: home, message: "Click Allow Access to let Lime save results beside files anywhere in your home folder.") != nil
    }

    static func remember(_ url: URL) {
        do {
            bookmarks[url.path] = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = url.startAccessingSecurityScopedResource()
        } catch {
            NSLog("[Lime] Could not remember access to %@: %@", url.path, error.localizedDescription)
        }
    }

    static func forget(_ path: String) { bookmarks[path] = nil }

    /// Re-opens remembered folders at launch; stale bookmarks are renewed.
    static func restore() {
        for (path, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                NSLog("[Lime] Folder access for %@ is no longer valid", path)
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            if stale { remember(url) }
        }
    }
}
