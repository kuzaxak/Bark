"""Bind the maintained Swift trap table to the selected SDK's known tail."""
from pathlib import Path
import re

BASE = Path(__file__).with_name("BridgeTable.swift")
TAILS = (
    ("BARC_HAS_PASSWORD_PROVIDER",
     'set_password_provider: { _ in fatalError("set_password_provider") }'),
    ("BARC_HAS_LOAD_PROGRESS", "tab_observe_load_progress: nil"),
    ("BARC_HAS_RENDERER_STATE", "tab_renderer_state: { _, _, _, _ in 0 }"),
    ("BARC_HAS_TAB_FAVICON", "tab_bind_favicon: { _, _ in 0 }"),
)


def write_bridge_fixture(header: Path, destination: Path) -> Path:
    text = BASE.read_text()
    sdk = header.read_text()
    tail = [member for flag, member in TAILS if re.search(rf"^#define\s+{flag}\s+1\b", sdk, re.MULTILINE)]
    if tail:
        text = text.rstrip().removesuffix(")") + ",\n    " + ",\n    ".join(tail) + ")\n"
    destination.write_text(text)
    return destination
