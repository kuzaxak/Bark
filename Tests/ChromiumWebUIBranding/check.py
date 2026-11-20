#!/usr/bin/env python3
"""Check generated Bark labels and optionally the locale packs in a built app."""

import argparse
import gzip
from pathlib import Path
import re
import runpy
import sys


PSEUDOLOCALES = ("ar_XB", "en_XA")

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


def check_about_page(framework, header, data_pack):
    resources = data_pack.ReadDataPack(framework / 'resources.pak').resources
    # Optimized builds bundle the page with other Settings elements. Resolve its
    # resource IDs from the generated header because they move across revisions.
    pattern = r'^#define IDR_SETTINGS_(?:[A-Z_]+_ROLLUP|ABOUT_PAGE_ABOUT_PAGE(?:_HTML)?)_JS (\d+)$'
    scripts = []
    for number in re.findall(pattern, header.read_text(), re.M):
        data = resources[int(number)]
        scripts.append(gzip.decompress(data) if data.startswith(b'\x1f\x8b') else data)
    javascript = b'\n'.join(scripts)
    for marker in (b'$i18n{aboutProductTitle}', b'$i18n{aboutBrowserVersion}', b'$i18nRaw{aboutProductLicense}'):
        if marker not in javascript:
            raise ValueError(f'The installed Settings scripts are missing {marker.decode()}')
    for marker in (b'id="updateStatusMessage"', b'chrome?p=update_error', b'update-status-changed'):
        if marker in javascript:
            raise ValueError(f'The installed Settings scripts still expose Chromium updates: {marker.decode()}')
    print('Checked the About page in the installed Settings scripts')


def missing_installed_packs(expected, installed, *, allow_missing_pseudolocales=False):
    missing = expected - installed
    if allow_missing_pseudolocales:
        for locale in PSEUDOLOCALES:
            family = {path for path in expected
                      if path.parent.stem == locale or path.parent.stem.startswith(f'{locale}_')}
            if family <= missing:
                missing -= family
    return missing


def check_installed(resources, generated, settings_header, data_pack, *, allow_missing_pseudolocales=False):
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
    missing = missing_installed_packs(expected.keys(), installed,
                                      allow_missing_pseudolocales=allow_missing_pseudolocales)
    unexpected = installed - expected.keys()
    if missing or unexpected:
        raise ValueError(f'Pack inventory differs. Missing {sorted(missing)}. Unexpected {sorted(unexpected)}.')
    for path in sorted(installed):
        source = expected[path]
        final = data_pack.ReadDataPack(path).resources
        for key, value in data_pack.ReadDataPack(source).resources.items():
            if final.get(key) != value:
                raise ValueError(f'{path.parent.name} resource {key} differs from {source.name}')
    print(f'Checked the generated browser strings in all {len(installed)} installed locale packs')
    check_about_page(framework, settings_header, data_pack)


def check_labels(locale, messages, ids, labels):
    base_locale, _, gender = locale.partition('_')
    failures = []
    for name in labels['_BARK_PRODUCT_LABELS']:
        value = messages.get(ids[name], b'').decode()
        # GRIT gender packs are sparse overrides. The base pack supplies the
        # fallback for strings that do not have a gender-specific translation.
        if not value and not gender:
            failures.append(f'{locale} missing product label: {name}')
            continue
        localized = labels['_BARK_LOCALIZED_BRANDS'].get((base_locale, name))
        forbidden = labels['_BARK_CHROMIUM_NAMES'] + ((localized[0],) if localized else ())
        if any(brand in value for brand in forbidden):
            failures.append(f'{locale} {name} retains an old browser name: {value}')
    for name, expected in CASE_LABELS.get(locale, {}).items():
        value = messages.get(ids[name], b'').decode()
        if expected not in value:
            failures.append(f'{locale} {name} expected {expected!r}: {value}')
    return failures


def check(grit_source, output, header_path, app, *, allow_missing_pseudolocales=False):
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
        failures.extend(check_labels(locale, messages, ids, labels))

    locales = {file.stem.removeprefix('branded_strings_') for file in files}
    if missing := CASE_LABELS.keys() - locales:
        failures.append(f'Missing required locale packs: {", ".join(sorted(missing))}')
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'Verified localized Bark product labels and Chromium V8 attribution in {len(files)} packs')
    if app is not None:
        check_installed(app / 'Contents/Resources', files, header_path.with_name('settings_resources.h'), data_pack,
                        allow_missing_pseudolocales=allow_missing_pseudolocales)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('grit_source', type=Path, help='Prepared Chromium source checkout')
    parser.add_argument('output', type=Path, help='Generated Bark locale pack directory')
    parser.add_argument('--header', type=Path, help='Optional explicit generated branded_strings.h')
    parser.add_argument('--app', type=Path, help='Also check every packaged product string in this Bark.app')
    parser.add_argument('--allow-missing-pseudolocales', action='store_true',
                        help='Allow an optimized engine to omit ar-XB and en-XA and all variants')
    args = parser.parse_args()
    if args.allow_missing_pseudolocales and args.app is None:
        parser.error('--allow-missing-pseudolocales requires --app')
    check(args.grit_source.resolve(), args.output.resolve(),
          args.header or args.output.parents[1] / 'chrome/grit/branded_strings.h', args.app,
          allow_missing_pseudolocales=args.allow_missing_pseudolocales)
