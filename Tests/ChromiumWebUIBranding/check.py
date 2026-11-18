#!/usr/bin/env python3
"""Check generated Bark labels and optionally the locale packs in a built app."""

import argparse
from pathlib import Path
import re
import runpy
import sys


CASE_LABELS = {
    'en-US': {
        'IDS_SETTINGS_ABOUT_PROGRAM': 'About Bark',
        'IDS_SETTINGS_DEFAULT_BROWSER_DEFAULT': 'Bark is your default browser',
        'IDS_SETTINGS_SITE_SETTINGS_CAMERA_BLOCKED_BY_OS': 'give Bark access',
        'IDS_EXTENSIONS_UNINSTALL': 'Remove from Bark',
        'IDS_EXTENSIONS_SHORTCUT_SCOPE_IN_CHROME': 'In Bark',
        'IDS_DOWNLOAD_WARNING_BYPASS_PROMPT_LEARN_MORE_LINK': 'Learn why Bark blocks',
        'IDS_SETTINGS_SITE_SETTINGS_JAVASCRIPT_OPTIMIZER_DESCRIPTION': "Chromium's V8 engine",
    },
    'de': {'IDS_SETTINGS_PRIVACY_GUIDE_PROMO_BODY': 'in Bark kennen'},
    'cs': {'IDS_SETTINGS_SITE_SETTINGS_PDFS_BLOCKED': 'Barku'},
    'hi': {'IDS_SETTINGS_ABOUT_PROGRAM': 'Bark के बारे में'},
    'tr': {'IDS_SETTINGS_DEFAULT_BROWSER_DEFAULT_THANK_YOU': "Bark'ı"},
    'ur': {'IDS_DOWNLOAD_WARNING_BYPASS_PROMPT_LEARN_MORE_LINK_ACCESSIBLE': 'Bark'},
}


def check_installed(resources, generated, data_pack):
    localizations = {path.parent.stem for path in resources.glob('*.lproj/InfoPlist.strings')}
    if not localizations:
        raise ValueError(f'No app localizations in {resources}')
    framework = resources.parent / 'Frameworks/Bark Framework.framework/Versions/Current/Resources'
    expected = {}
    for file in generated:
        locale, _, gender = file.stem.removeprefix('branded_strings_').partition('_')
        name = 'en' if locale == 'en-US' else locale.replace('-', '_')
        if name in localizations:
            directory = f'{name}_{gender}' if gender else name
            expected[framework / f'{directory}.lproj/locale.pak'] = file
    names = {path.parent.stem for path in expected}
    if missing := localizations - names:
        raise ValueError(f'No generated browser strings for installed locales {sorted(missing)}')
    installed = set(framework.glob('*.lproj/locale.pak'))
    if expected.keys() != installed:
        raise ValueError(f'Pack inventory differs. Missing {sorted(expected.keys() - installed)}. '
                         f'Unexpected {sorted(installed - expected.keys())}.')
    for path, source in expected.items():
        final = data_pack.ReadDataPack(path).resources
        for key, value in data_pack.ReadDataPack(source).resources.items():
            if final.get(key) != value:
                raise ValueError(f'{path.parent.name} resource {key} differs from {source.name}')
    print(f'Checked the generated browser strings in all {len(installed)} installed locale packs')


def check(grit_source, output, header_path, app):
    sys.path.insert(0, str(grit_source / 'tools/grit'))
    from grit.format import data_pack

    recipe = Path(__file__).resolve().parents[2] / 'Runtime/Chromium/bark/app/rebrand_locales.py'
    labels = runpy.run_path(str(recipe))
    header = header_path.read_text()
    ids = {name: int(number) for name, number in re.findall(r'^#define (\w+) (\d+)$', header, re.M)}
    files = sorted(output.glob('branded_strings_*.pak'))
    if not files:
        raise ValueError(f'No branded_strings packs in {output}')
    failures = []
    for file in files:
        locale = file.stem.removeprefix('branded_strings_')
        messages = data_pack.ReadDataPack(file).resources
        for name in labels['_BARK_PRODUCT_LABELS']:
            value = messages.get(ids[name], b'').decode()
            localized = labels['_BARK_LOCALIZED_BRANDS'].get((locale.split('_')[0], name))
            forbidden = labels['_BARK_CHROMIUM_NAMES'] + ((localized[0],) if localized else ())
            if any(brand in value for brand in forbidden):
                failures.append(f'{locale} {name} retains an old browser name: {value}')
        for name, expected in CASE_LABELS.get(locale, {}).items():
            value = messages.get(ids[name], b'').decode()
            if expected not in value:
                failures.append(f'{locale} {name} expected {expected!r}: {value}')

    locales = {file.stem.removeprefix('branded_strings_') for file in files}
    if missing := CASE_LABELS.keys() - locales:
        failures.append(f'Missing required locale packs: {", ".join(sorted(missing))}')
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'Verified localized Bark product labels and Chromium V8 attribution in {len(files)} packs')
    if app is not None:
        check_installed(app / 'Contents/Resources', files, data_pack)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('grit_source', type=Path, help='Prepared Chromium source checkout')
    parser.add_argument('output', type=Path, help='Generated Bark locale pack directory')
    parser.add_argument('--header', type=Path, help='Optional explicit generated branded_strings.h')
    parser.add_argument('--app', type=Path, help='Also check every packaged product string in this Bark.app')
    args = parser.parse_args()
    check(args.grit_source.resolve(), args.output.resolve(),
          args.header or args.output.parents[1] / 'chrome/grit/branded_strings.h', args.app)
