#!/usr/bin/env python3
"""Read the signed Bark build information through its native Help menu."""

from pathlib import Path
import plistlib
import runpy
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(HERE.parent / "Shared"))
from chromium_sdk_layout import native_architecture, read_pin
from signed_walk import Accessibility, run_walk, wait_for


def main():
    expected = []
    fixture = runpy.run_path(str(HERE.parent / "ChromiumExtensionActions/walk.py"))

    def prepare(root, origin, app, profile):
        contents = app / "Contents"
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        framework = contents / "Frameworks/Bark Framework.framework/Versions/Current/Resources/Info.plist"
        engine = plistlib.loads(framework.read_bytes())
        arch = native_architecture()
        expected.extend([f"Bark {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']})",
                         f"Chromium {engine['CFBundleShortVersionString']}", f"Architecture {arch}",
                         "Engine SDK SHA-256", read_pin(REPO / "Packages/BarkEngine", arch)])

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)
        wait_for("The disposable source did not load", lambda: "/ready" in events, process, timeout=30)
        access.menu("Build Information…")
        try:
            done = access.control("Done", ("AXButton",))
            window = access.owner("Done", ("AXButton",))
            labels = {name for element in access.tree(window) for name in access.names(element)}
            if "\n".join(expected) not in labels:
                raise RuntimeError("Build Information differs from the app, engine or checkout pin")
            copy = access.control("Copy", ("AXButton",), root=window)
            if not access.attribute(copy, "AXEnabled"):
                raise RuntimeError("Build Information cannot be copied")
            (output / "build-information.txt").write_text("\n".join(expected) + "\n")
            access.press(done)
            wait_for("Build Information did not close", lambda: access.find("Done", ("AXButton",)) is None, process)
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        except Exception:
            access.dump(output / "build-information-ax.json")
            raise

    return run_walk(__doc__, "build-information", fixture["serve"], exercise,
                    prepare_fixture=prepare, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
