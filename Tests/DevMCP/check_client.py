"""Exercise Bark's outgoing MCP identity through the real stdio handshake."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests/Shared"))
from swift_check import build_package, swift_target


def serve_stdio(transcript):
    with transcript.open("x") as output:
        for line in sys.stdin:
            request = json.loads(line)
            output.write(line)
            output.flush()
            method = request["method"]
            if method == "notifications/initialized":
                continue
            if method == "initialize":
                result = {"protocolVersion": request["params"]["protocolVersion"],
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [{"name": "fixture", "inputSchema": {"type": "object"}}]}
            else:
                raise ValueError(method)
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def check(out):
    target = swift_target()
    settings = build_package(ROOT / "Packages/NookSettings", out / "settings", target)
    contents = out / "Bark.app/Contents"
    binary = contents / "MacOS/Bark"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "ee.qdo.bark.handshake-fixture", "CFBundleExecutable": "Bark",
        "CFBundlePackageType": "APPL", "CFBundleName": "Internal", "CFBundleDisplayName": "Bark",
        "CFBundleShortVersionString": "4.2",
    }))
    mcp = ROOT / "Nook/Managers/AIManager/MCP"
    subprocess.run(["swiftc", "-swift-version", "5", "-target", target, "-parse-as-library",
                    "-I", settings / "Modules", ROOT / "Nook/Models/AI/MCPModels.swift",
                    mcp / "MCPTransport.swift", mcp / "MCPClient.swift", ROOT / "Tests/DevMCP/Client.swift",
                    settings / "NookSettings.build/MCPServerConfig.swift.o",
                    settings / "NookSettings.build/ProductDisplayName.swift.o", "-o", binary], check=True)
    transcript = out / "handshake.jsonl"
    subprocess.run([binary, sys.executable, "-B", Path(__file__).resolve(), "--peer", transcript],
                   check=True, timeout=25)
    messages = [json.loads(line) for line in transcript.read_text().splitlines()]
    assert [m["method"] for m in messages] == ["initialize", "notifications/initialized", "tools/list"]
    identity = messages[0]["params"]["clientInfo"]
    if identity != {"name": "Bark", "version": "4.2"}:
        raise ValueError(f"Unexpected clientInfo: {identity}")
    print("Bark and its bundle version reached the MCP server; stdio tool discovery passed.")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--peer":
        serve_stdio(Path(sys.argv[2]))
    else:
        with TemporaryDirectory(prefix="bark-mcp-client-") as directory:
            check(Path(directory))
