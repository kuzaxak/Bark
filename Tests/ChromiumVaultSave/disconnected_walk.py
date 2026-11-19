#!/usr/bin/env python3
"""Verify exclusive Pawl does not fall back to Chromium when its companion is unavailable."""

from contextlib import contextmanager
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import sys
from threading import Thread
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fixture_support import prepare_engine_profile, verification_shell_code

vault = runpy.run_path(str(HERE / "walk.py"))
from signed_walk import run_walk, wait_for

UNAVAILABLE = "Pawl Vault is unavailable. Open Pawl Vault and try again."
PROBE = """
<script>
const field = document.querySelector("[name=password]");
field?.addEventListener("pointerdown", event => {
    if (!event.isTrusted) return;
    const reportEmpty = path => {
        const empty = !field.value && !document.querySelector("[name=username]").value;
        fetch(path, {method: "POST", keepalive: true, body: empty ? "fields-empty" : "fields-populated"});
    };
    reportEmpty("/disconnected-probe/click");
    setTimeout(() => reportEmpty("/disconnected-probe/settled"), 800);
}, {once: true});
</script>
"""


class Fixture(vault["Fixture"]):
    def do_POST(self):
        if self.path not in ("/disconnected-probe/click", "/disconnected-probe/settled"):
            super().do_POST()
            return
        size = int(self.headers.get("Content-Length", 0))
        if not 0 < size <= 32:
            self.send_error(400)
            return
        observation = self.rfile.read(size)
        if observation not in (b"fields-empty", b"fields-populated"):
            self.send_error(400)
            return
        self.server.events.append(self.path.rsplit("/", 1)[-1] + ":" + observation.decode("ascii"))
        self.send_response(204)
        self.end_headers()


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.html = (HERE / "fixture.html").read_bytes() + PROBE.encode()
        server.events = []
        server.assertion_log = None
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def main():
    engine_profile = None

    def prepare(root, _origin, app, profile):
        nonlocal engine_profile
        verification_shell_code(app)
        # The verification constructor supplies an in-memory transport without
        # a VaultFixture, so it returns .notRunning and never opens the socket.
        if (root / "VaultFixture.json").exists():
            raise RuntimeError("The disconnected walk requires an empty vault configuration")
        engine_profile = prepare_engine_profile(root, profile)

    def exercise(screen, process, events, output):
        controls = vault["CandidateControls"](screen, process)

        def seen(event, timeout=14):
            return wait_for(f"Missing fixture event {event}", lambda: event in events, process, timeout=timeout)

        def observe_no_prompt():
            deadline = time.monotonic() + 2

            def settled():
                screen.guard()
                if any(controls.find(title, ()) for title in (
                    "Save password?", "Update password?", "Save password to Pawl Vault?",
                    "Update password in Pawl Vault?", "Open Pawl Vault to save this login",
                    "Review this login in Pawl Vault",
                )) or controls.find(vault["EXISTING_ACCOUNT"], ("AXButton",), partial=True):
                    raise RuntimeError("A credential picker or save prompt appeared while Pawl was unavailable")
                return time.monotonic() >= deadline

            wait_for("Credential UI observation did not settle", settled, process)

        try:
            seen("ready:/source", timeout=30)
            screen.guard()
            controls.ax.AXUIElementSetAttributeValue(controls.app, "AXEnhancedUserInterface", True)
            screen.keys.update({",": 43, "ArrowDown": 125})
            screen.key(",", screen.command)
            general = controls.require("General", ("AXWindow",))
            controls.press("Privacy", root=general)
            settings = controls.require("Privacy", ("AXWindow",))
            def provider_notice():
                if controls.find("Pawl Vault works alongside Chromium", (), partial=True, root=settings):
                    raise RuntimeError("This signed Bark uses Pawl alongside Chromium. Exclusive provider selection requires a newer SDK.")
                return controls.find("Quit and reopen Bark to change password providers.", (), partial=True, root=settings)

            wait_for("Missing launch-time Pawl provider notice", provider_notice, process)
            controls.require(UNAVAILABLE, root=settings, partial=True)
            screen.screenshot(output / "unavailable.png", include_owned_windows=True)
            vault["close_settings"](controls, settings)

            controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
            seen("click:fields-empty")
            screen.key("ArrowDown")
            seen("settled:fields-empty")
            observe_no_prompt()
            if any(event.endswith(":fields-populated") for event in events):
                raise RuntimeError("A provider populated fields before user input")

            # The normal fixture server compares the submitted values exactly.
            for label, value in (("Fixture account", vault["EXISTING_ACCOUNT"]),
                                 ("Fixture password", vault["UPDATED_PASSWORD"])):
                controls.click(label, ("AXTextField", "AXSecureTextField"))
                screen.key(value, unicode=True)
            controls.click("Sign in to fixture", ("AXButton",))
            seen("updated-fixture-submitted")
            seen("ready:/existing-signed-in")
            observe_no_prompt()

            screen.key("q", screen.command)
            controls.press("Quit")
            if process.wait(timeout=30) != 0:
                raise RuntimeError("Bark did not quit cleanly before the Chromium store check")
            vault["check_chromium_stores"](engine_profile, output)
            log = (output / "app.log").read_text(errors="replace")
            if "leak_detection_request" in log:
                raise RuntimeError("Chromium attempted a password leak check in the disposable fixture")
            (output / "disconnected.json").write_text(json.dumps({
                "status": UNAVAILABLE, "exclusive_pawl": True,
                "empty_fields_after_trusted_click": True, "validated_submission": True,
                "save_prompt_visible": False, "stock_store_rows": 0,
            }, indent=2) + "\n")
        except Exception:
            if process.poll() is None:
                controls.dump(output)
            raise

    return run_walk(__doc__, "vault-disconnected", serve, exercise, source_host="localhost",
                    prepare_fixture=prepare, official_qualification=True,
                    preferences=(("settings.pawlVaultEnabled", "-bool", "true"),))


if __name__ == "__main__":
    sys.exit(main())
