// Licensed under GPL-3.0. See LICENSE.

/// The scopes the user approved for the rest of the current chat.
struct ChatToolApprovals {
    enum Scope: Hashable {
        case browser
        case mcpServer(String)
    }

    private var scopes: Set<Scope> = []

    func allows(_ scope: Scope) -> Bool {
        scopes.contains(scope)
    }

    mutating func allow(_ scope: Scope) {
        scopes.insert(scope)
    }
}
