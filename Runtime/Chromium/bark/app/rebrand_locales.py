#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Apply Bark's product name to selected localized browser UI messages."""

import argparse
from pathlib import Path
import shutil
import sys


# Bark preserves GRIT translation IDs and reuses the surrounding localized
# copy. Only substitute labels whose subject is the browser product.
_BARK_PRODUCT_LABELS = frozenset((
    'IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_DEEP_SCANNING_PROMPT_LOCAL_DECRYPTION',
    'IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_UNKNOWN_SOURCE',
    'IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_BLOCKED_LEARN_MORE_LINK',
    'IDS_DOWNLOAD_STATUS_CRX_INSTALL_RUNNING',
    'IDS_DOWNLOAD_WARNING_BYPASS_PROMPT_LEARN_MORE_LINK',
    'IDS_DOWNLOAD_WARNING_BYPASS_PROMPT_LEARN_MORE_LINK_ACCESSIBLE',
    'IDS_EXTENSION_ALERT_ITEM_BLOCKLISTED_MALWARE',
    'IDS_EXTENSION_INSTALLED_HEADING',
    'IDS_EXTENSION_UNINSTALL_PROMPT_REMOVE_DATA_CHECKBOX',
    'IDS_EXTENSIONS_ALERT_ITEM_BLOCKLISTED_MALWARE_TITLE',
    'IDS_EXTENSIONS_INCOGNITO_WARNING',
    'IDS_EXTENSIONS_ITEM_SHOW_ACCESS_REQUESTS_IN_TOOLBAR',
    'IDS_EXTENSIONS_MENU_ZERO_STATE_DESC',
    'IDS_EXTENSIONS_MULTIPLE_UNSUPPORTED_DISABLED_BODY',
    'IDS_EXTENSIONS_MV2_DEPRECATION_MESSAGE_DISABLED_SUBTITLE',
    'IDS_EXTENSIONS_MV2_DEPRECATION_PANEL_DISABLED_SUBTITLE',
    'IDS_EXTENSIONS_MV2_DEPRECATION_PANEL_REMOVE_BUTTON_ACC_LABEL',
    'IDS_EXTENSIONS_SAFETY_CHECK_NO_PRIVACY_PRACTICES',
    'IDS_EXTENSIONS_SAFETY_CHECK_OFFSTORE',
    'IDS_EXTENSIONS_SAFETY_CHECK_OFFSTORE_OFF',
    'IDS_EXTENSIONS_SAFETY_CHECK_OFFSTORE_ON',
    'IDS_EXTENSIONS_SAFETY_CHECK_PRIMARY_LABEL',
    'IDS_EXTENSIONS_SC_DESCRIPTION',
    'IDS_EXTENSIONS_SETTINGS_API_SECOND_LINE_START_AND_SEARCH',
    'IDS_EXTENSIONS_SETTINGS_API_SECOND_LINE_START_PAGES',
    'IDS_EXTENSIONS_SHORTCUT_SCOPE_IN_CHROME',
    'IDS_EXTENSIONS_SINGLE_UNSUPPORTED_DISABLED_BODY',
    'IDS_EXTENSIONS_UNINSTALL',
    'IDS_FIRST_RUN_DIALOG_WINDOW_TITLE',
    'IDS_SETTINGS_ABOUT_PROGRAM',
    'IDS_SETTINGS_CUSTOMIZE_YOUR_CHROME_PROFILE',
    'IDS_SETTINGS_DEFAULT_BROWSER_DEFAULT',
    'IDS_SETTINGS_DEFAULT_BROWSER_DEFAULT_THANK_YOU',
    'IDS_SETTINGS_DEFAULT_BROWSER_ERROR',
    'IDS_SETTINGS_DEFAULT_BROWSER_MAKE_DEFAULT',
    'IDS_SETTINGS_DEFAULT_BROWSER_MAKE_DEFAULT_USER_VALUE',
    'IDS_SETTINGS_DEFAULT_BROWSER_SECONDARY',
    'IDS_SETTINGS_GET_HELP_USING_CHROME',
    'IDS_SETTINGS_HTTPS_FIRST_MODE_DISABLED_SUBLABEL',
    'IDS_SETTINGS_HTTPS_FIRST_MODE_ENABLED_FULL_SUBLABEL',
    'IDS_SETTINGS_HTTPS_FIRST_MODE_ENABLED_INCOGNITO_SUBLABEL',
    'IDS_SETTINGS_HTTPS_FIRST_MODE_SUBTITLE',
    'IDS_SETTINGS_PRIVACY_GUIDE_PROMO_BODY',
    'IDS_SETTINGS_RESTART_TO_APPLY_CHANGES',
    'IDS_SETTINGS_SAFETY_HUB_VERSION_NAVIGATION_ARIA_LABEL',
    'IDS_SETTINGS_SITE_DATA_PAGE_CLEAR_ON_EXIT_WITH_EXCEPTION_RADIO_SUBLABEL',
    'IDS_SETTINGS_SITE_DATA_PAGE_DELETE_ON_EXIT_EXCEPTIONS_SUB_HEADING',
    'IDS_SETTINGS_SITE_SETTINGS_CAMERA_BLOCKED_BY_OS',
    'IDS_SETTINGS_SITE_SETTINGS_LOCATION_BLOCKED_BY_OS',
    'IDS_SETTINGS_SITE_SETTINGS_MIC_BLOCKED_BY_OS',
    'IDS_SETTINGS_SITE_SETTINGS_PDFS_BLOCKED',
    'IDS_SETTINGS_SITE_SITE_DETAILS_CAMERA_BLOCKED_BY_OS',
    'IDS_SETTINGS_SITE_SITE_DETAILS_LOCATION_BLOCKED_BY_OS',
    'IDS_SETTINGS_SITE_SITE_DETAILS_MICROPHONE_BLOCKED_BY_OS',
))
# Hindi and the accent pseudo-locale use distinct spellings. A handful of
# translations inflect the name or directly refer to Chrome as the browser.
_BARK_CHROMIUM_NAMES = ('Chromium', 'क्रोमियम', 'Çĥrömîûm')
_BARK_LOCALIZED_BRANDS = {
    ('cs', 'IDS_SETTINGS_SITE_SETTINGS_PDFS_BLOCKED'): ('Chromiu', 'Barku'),
    ('de', 'IDS_SETTINGS_PRIVACY_GUIDE_PROMO_BODY'): ('Chrome', 'Bark'),
    ('fr', 'IDS_EXTENSIONS_MULTIPLE_UNSUPPORTED_DISABLED_BODY'): ('Chrome', 'Bark'),
    ('gu', 'IDS_SETTINGS_DEFAULT_BROWSER_SECONDARY'): ('Google Chrome', 'Bark'),
    ('ms', 'IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_UNKNOWN_SOURCE'): ('Chrome', 'Bark'),
    ('tr', 'IDS_SETTINGS_DEFAULT_BROWSER_DEFAULT_THANK_YOU'): ("Chrome'u", "Bark'ı"),
    ('ur', 'IDS_DOWNLOAD_WARNING_BYPASS_PROMPT_LEARN_MORE_LINK_ACCESSIBLE'): ('Chrome', 'Bark'),
}


def rebrand_label(name, lang, value):
    localized = _BARK_LOCALIZED_BRANDS.get((lang, name))
    if localized:
        value = value.replace(*localized)
    for brand in _BARK_CHROMIUM_NAMES:
        value = value.replace(brand, 'Bark')
    return value


def build(source, output, files):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/grit'))
    from grit.format import data_pack

    output.mkdir(parents=True, exist_ok=True)
    for filename in files:
        pack_path = source / filename
        locale = pack_path.stem.removeprefix('branded_strings_').split('_', 1)[0]
        pack = data_pack.ReadDataPack(pack_path)
        if pack.encoding != data_pack.UTF8:
            raise ValueError(f'{pack_path}: expected UTF-8 branded strings')
        for resource, info in data_pack.ReadGrdInfo(str(pack_path)).items():
            if info.textual_id in _BARK_PRODUCT_LABELS and resource in pack.resources:
                value = pack.resources[resource].decode('utf-8')
                pack.resources[resource] = rebrand_label(info.textual_id, locale, value).encode('utf-8')
        data_pack.WriteDataPack(pack.resources, output / filename, pack.encoding)
        shutil.copyfile(source / (filename + '.info'), output / (filename + '.info'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('files', nargs='+')
    args = parser.parse_args()
    build(args.source, args.output, args.files)
