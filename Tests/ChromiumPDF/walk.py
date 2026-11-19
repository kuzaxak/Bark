"""Test printing a synthetic PDF in signed Bark without using a printer."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

TITLE = "Bark loopback PDF"

def make_fixture_pdf():
    stream = b"BT /F1 18 Tf 32 300 Td (Bark loopback PDF) Tj ET\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length %d >>\nstream\n%s" % (len(stream), stream) + b"endstream",
        b"<< /Title (Bark loopback PDF) >>",
    ]
    pdf = bytearray(b"%PDF-1.4\n")
    positions = []
    for number, body in enumerate(objects, 1):
        positions.append(len(pdf))
        pdf.extend(b"%d 0 obj\n%s\nendobj\n" % (number, body))
    index = len(pdf)
    pdf.extend(b"xref\n0 7\n0000000000 65535 f \n")
    for position in positions:
        pdf.extend(b"%010d 00000 n \n" % position)
    pdf.extend(b"trailer\n<< /Root 1 0 R /Size 7 /Info 6 0 R >>\nstartxref\n%d\n%%%%EOF\n" % index)
    return pdf


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/source":
            data = self.server.pdf
            mime = "application/pdf"
            self.server.events.append("served PDF")
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Disposition", 'inline; filename="bark-loopback.pdf"')
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        server.pdf = make_fixture_pdf()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def exercise(screen, proc, events, output):
    # The native preview can show local printer display names.
    output.chmod(0o700)
    access = Accessibility(screen, proc)
    try:
        wait_for("PDF was not served", lambda: "served PDF" in events, proc)
        pdf_owner = wait_for("PDF document/viewer title not found",
                             lambda: access.owner(TITLE) or access.owner("bark-loopback.pdf"), proc)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        screen.screenshot(output / "pdf.png", include_owned_windows=True)
        screen.key("p", screen.command)
        preview = access.control("Print", ("AXWindow",))
        host_link = access.find("Print", ("AXGroup",), root=pdf_owner)
        if preview == pdf_owner or host_link is None:
            raise RuntimeError("The PDF's own window has no attached Print group")
        try:
            access.control("Destination", root=preview)
            access.control("Cancel", ("AXButton",), root=preview)
            summary = wait_for("Print preview did not report the PDF’s one page",
                               lambda: next((value for element in access.tree(preview)
                                             for value in access.names(element)
                                             if "1 sheet" in value.lower() or "1 page" in value.lower()), None), proc)
        finally:
            screen.screenshot(output / "print-preview.png", include_owned_windows=True)
        screen.key("Escape")
        wait_for("Print preview did not dismiss", lambda: not access.find("Print", ("AXWindow",)), proc)
        if pdf_owner not in access.windows() or not (access.find(TITLE, root=pdf_owner) or access.find("bark-loopback.pdf", root=pdf_owner)):
            raise RuntimeError("Cancel did not return to the original PDF")
        (output / "pdf.json").write_text(json.dumps({
            "print_preview_owner_unchanged": True, "summary": summary,
            "cancelled": True, "pdf_remained_open": True,
        }, indent=2) + "\n")
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), proc))
    except Exception:
        access.dump(output / "accessibility.json")
        raise


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "pdf", serve, exercise, official_qualification=True))
