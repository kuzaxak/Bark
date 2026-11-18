#!/usr/bin/env python3
"""Check that the Mac Bark About page delegates updates to the application menu."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def check(source):
    about = source / 'chrome/browser/resources/settings/about_page'
    preprocessor = source / 'tools/grit/preprocess_if_expr.py'
    with tempfile.TemporaryDirectory(prefix='bark-about-webui-') as directory:
        for name, target, google, testing, has_updater in (
            ('Bark', 'darwin', False, False, False),
            ('Chrome', 'darwin', True, False, True),
            ('Chrome for Testing', 'darwin', False, True, True),
            ('Linux Chromium', 'linux', False, False, True),
        ):
            output = Path(directory) / name
            subprocess.run([
                sys.executable, '-B', preprocessor,
                '--in-folder', about, '--out-folder', output,
                '--in-files', 'about_page.ts', 'about_page.html.ts',
                '-t', target, '-D', f'_google_chrome={str(google).lower()}',
                '-D', f'_is_chrome_for_testing_branded={str(testing).lower()}',
            ], check=True)
            script = (output / 'about_page.ts').read_text()
            page = (output / 'about_page.html.ts').read_text()
            for marker in ('this.aboutBrowserProxy_.pageReady()', 'this.aboutBrowserProxy_.refreshUpdateStatus()'):
                if (marker in script) != has_updater:
                    raise SystemExit(f'{name} has incorrect startup behavior for {marker}')
            for marker in ('id="updateStatusMessage"', 'id="relaunch"', 'chrome?p=update_error'):
                if (marker in page) != has_updater:
                    raise SystemExit(f'{name} has incorrect update UI for {marker}')
            for marker in ('$i18n{aboutBrowserVersion}', '$i18n{aboutProductTitle}', '$i18nRaw{aboutProductLicense}'):
                if marker not in page:
                    raise SystemExit(f'{name} lost About page content {marker}')
            print(f'{name}: About update and attribution contract passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Prepared Chromium source checkout')
    check(parser.parse_args().source.resolve())
