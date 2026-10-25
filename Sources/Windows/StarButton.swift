import SwiftUI

/// Small "Star Lime on GitHub" pill for the intro's last page and About.
struct StarButton: View {
    @ObservedObject var star: GitHubStar = .shared
    private static let gold = Color(red: 0.89, green: 0.63, blue: 0.03)

    var body: some View {
        VStack(spacing: 6) {
            Button { Task { await star.star() } } label: {
                HStack(spacing: 6) {
                    if star.state == .starring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: starred ? "star.fill" : "star").foregroundStyle(starred ? Color(nsColor: Brand.accentDeep) : Self.gold)
                    }
                    Text(title)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(starred ? Color(nsColor: Brand.accentDeep) : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(starred ? Color(nsColor: Brand.accent).opacity(0.16) : Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(PillPress())
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 14)
        }
    }

    private var starred: Bool { star.state == .starred }

    private var title: String {
        switch star.state {
        case .starring: "Starring…"
        case .starred: "Starred on GitHub"
        case .idle, .openedPage: "Star Lime on GitHub"
        }
    }

    private var hint: String {
        switch star.state {
        case .openedPage: "Opened GitHub in your browser."
        case .starred: "Thanks for the star."
        case .idle, .starring: ""
        }
    }
}

/// Dims the pill while pressed and draws nothing else around it.
private struct PillPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
