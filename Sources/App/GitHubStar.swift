import AppKit

/// Stars Lime on GitHub. With the GitHub CLI signed in, the star is given
/// right away and nothing opens; otherwise the repository opens in the
/// browser. Only ever runs when the person clicks the button.
@MainActor
final class GitHubStar: ObservableObject {
    enum State: Equatable { case idle, starring, starred, openedPage }

    static let shared = GitHubStar()
    nonisolated static let repository = "LumenJSN/Lime"
    nonisolated static let page = URL(string: "https://github.com/\(repository)")!
    /// Where Homebrew and MacPorts put `gh`; apps don't get the shell's PATH.
    nonisolated static let cliLocations = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
    nonisolated static let starArguments = ["api", "--method", "PUT", "user/starred/\(repository)", "--silent"]
    /// A slow network or a keychain prompt shouldn't leave the button spinning.
    nonisolated static let timeout: UInt64 = 8_000_000_000

    @Published private(set) var state: State
    private let defaults: UserDefaults
    private let locations: [String]
    private let openPage: (URL) -> Void

    init(defaults: UserDefaults = .standard, locations: [String] = cliLocations,
         openPage: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.locations = locations
        self.openPage = openPage
        state = defaults.bool(forKey: "starredOnGitHub") ? .starred : .idle
    }

    func star() async {
        guard state == .idle || state == .openedPage else { return }
        guard let cli = Self.cli(in: locations) else { return showPage() }
        state = .starring
        if await Self.run(cli) {
            defaults.set(true, forKey: "starredOnGitHub")
            state = .starred
        } else {
            showPage()
        }
    }

    nonisolated static func cli(in locations: [String]) -> URL? {
        locations.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func showPage() {
        openPage(Self.page)
        state = .openedPage
    }

    /// True once GitHub took the star; false when `gh` isn't signed in, fails or times out.
    private nonisolated static func run(_ cli: URL) async -> Bool {
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        let env = environment
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await ProcessRunner.run(cli, starArguments, environment: env)) != nil }
            group.addTask { try? await Task.sleep(nanoseconds: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
