from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import build_package, swift_target

target = swift_target()

with TemporaryDirectory(prefix='bark-favorite-card-check-') as directory:
    out = Path(directory)
    scratch = out / 'packages/NookDesign'
    debug = build_package(root / 'Packages/NookDesign', scratch, target)
    card = (root / 'App/Chromium/ChromiumFavoriteCard.swift').read_text()
    preview = (root / 'Nook/Components/Sidebar/PinnedButtons/FavoritePreview.swift').read_text()
    a = preview.index('/// Where the hovered favorite')
    placement = preview[a:preview.index('\n}\n', a) + 3]
    (out / 'Shipped.swift').write_text('import AppKit\nimport NookDesign\nimport SwiftUI\n\n' + card[card.index('struct ChromiumFavoriteCardPanel'):] + '\n' + placement)
    objects = sorted(str(o) for o in (debug / 'NookDesign.build').glob('*.o'))
    binary = out / 'chromium-favorite-card-check'
    c = ['swiftc', '-swift-version', '5', '-target', target, '-parse-as-library', '-I', str(debug / 'Modules'),
         str(out / 'Shipped.swift'), str(root / 'Tests/ChromiumFavoriteCard/Main.swift'), *objects, '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
