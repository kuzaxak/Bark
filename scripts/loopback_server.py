# Licensed under GPL-3.0. See LICENSE.
"""Threading HTTP server for test fixtures that stays on the IPv4 loopback address."""

from http.server import ThreadingHTTPServer
from socketserver import TCPServer

LOOPBACK = "127.0.0.1"


class LoopbackHTTPServer(ThreadingHTTPServer):
    def __init__(self, handler, port=0):
        super().__init__((LOOPBACK, port), handler)

    def server_bind(self):
        # HTTPServer.server_bind names the server with socket.getfqdn, a reverse lookup macOS sends to mDNSResponder.
        TCPServer.server_bind(self)
        self.server_name = LOOPBACK
        self.server_port = self.server_address[1]
