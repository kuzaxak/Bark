// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings

@main
struct ClientHandshake {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let transport = MCPTransportType.stdio(command: arguments[1], args: Array(arguments.dropFirst(2)))
        let config = MCPServerConfig(name: "Fixture", transport: transport)
        let client = MCPClient(serverConfig: config)
        try await client.connect()
        let tools = await client.discoveredTools
        await client.disconnect()
        precondition(tools.map(\.name) == ["fixture"], "Bark did not discover the stdio peer’s tool")
    }
}
