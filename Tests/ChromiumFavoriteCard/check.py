from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-favorite-card-check-') as directory:
    out = Path(directory)
    scratch = out / 'packages/NookDesign'
    p = subprocess.run(['swift', 'build', '--package-path', str(root / 'Packages/NookDesign'), '--scratch-path', str(scratch), '--jobs', '2'], capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    card = (root / 'App/Chromium/ChromiumFavoriteCard.swift').read_text()
    preview = (root / 'Nook/Components/Sidebar/PinnedButtons/FavoritePreview.swift').read_text()
    a = preview.index('/// Where the hovered favorite')
    placement = preview[a:preview.index('\n}\n', a) + 3]
    (out / 'Shipped.swift').write_text('import AppKit\nimport NookDesign\nimport SwiftUI\n\n' + card[card.index('struct ChromiumFavoriteCardPanel'):] + '\n' + placement)
    debug = scratch / 'x86_64-apple-macosx/debug'
    objects = sorted(str(o) for o in (debug / 'NookDesign.build').glob('*.o'))
    binary = out / 'chromium-favorite-card-check'
    c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', '-I', str(debug / 'Modules'),
         str(out / 'Shipped.swift'), str(root / 'Tests/ChromiumFavoriteCard/Main.swift'), *objects, '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
