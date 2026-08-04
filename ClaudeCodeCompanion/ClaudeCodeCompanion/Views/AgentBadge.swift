import SwiftUI

/// Small capsule marking which agent a session or search result came from.
/// Claude Code sessions stay unbadged so the common case reads cleanly.
struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 8, weight: .semibold))
            Text(agent.badgeText)
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
        .help("\(agent.displayName) conversation")
    }

    private var tint: Color {
        switch agent {
        case .claude: return DesignConstants.accentColor
        case .codex: return .teal
        case .cursor: return .purple
        }
    }
}

/// Row of agent marks for a project that holds more than one agent's history.
struct AgentMarks: View {
    let agents: Set<AgentKind>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AgentKind.allCases.filter { agents.contains($0) && $0 != .claude }) { agent in
                Image(systemName: agent.symbolName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Includes \(agent.displayName) history")
            }
        }
    }
}
