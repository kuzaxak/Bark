// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings

@main
struct ClientHandshake {
    static func main() async throws {
        checkChatToolApprovals()
        let arguments = CommandLine.arguments
        let transport = MCPTransportType.stdio(command: arguments[1], args: Array(arguments.dropFirst(2)))
        let config = MCPServerConfig(name: "Fixture", transport: transport)
        let client = MCPClient(serverConfig: config)
        try await client.connect()
        let tools = await client.discoveredTools
        await client.disconnect()
        precondition(tools.map(\.name) == ["fixture"], "Bark did not discover the stdio peer’s tool")
    }

    static func checkChatToolApprovals() {
        let first = ChatToolApprovals.Scope.mcpServer("first")
        let second = ChatToolApprovals.Scope.mcpServer("second")
        var approvals = ChatToolApprovals()
        precondition(!approvals.allows(.browser) && !approvals.allows(first))
        approvals.allow(.browser)
        precondition(approvals.allows(.browser) && !approvals.allows(first))
        approvals = ChatToolApprovals()
        approvals.allow(first)
        precondition(approvals.allows(first) && !approvals.allows(.browser) && !approvals.allows(second))
        approvals.allow(second)
        precondition(approvals.allows(first) && approvals.allows(second))
        approvals = ChatToolApprovals()
        precondition(!approvals.allows(first) && !approvals.allows(second))
    }
}
