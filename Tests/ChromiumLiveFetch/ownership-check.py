from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[2]
sys.exit(subprocess.call([sys.executable, "-B", repo / "scripts/bark-check.py", "live-fetch"]))
