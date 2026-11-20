"""Exercise locale-label requirements without a Chromium checkout."""

from pathlib import Path
import unittest

from check import check_labels, missing_installed_packs


class ProductLabelsTests(unittest.TestCase):
    def test_base_label_is_required_but_gender_override_may_be_sparse(self):
        name = "IDS_EXTENSIONS_MENU_ZERO_STATE_DESC"
        ids = {name: 1}
        labels = {
            "_BARK_PRODUCT_LABELS": (name,),
            "_BARK_LOCALIZED_BRANDS": {},
            "_BARK_CHROMIUM_NAMES": ("Chromium",),
        }
        self.assertEqual(check_labels("es", {}, ids, labels), [f"es missing product label: {name}"])
        self.assertEqual(check_labels("es", {1: b""}, ids, labels), [f"es missing product label: {name}"])
        self.assertEqual(check_labels("es", {1: b"Bark"}, ids, labels), [])
        self.assertEqual(check_labels("es_feminine", {}, ids, labels), [])
        self.assertEqual(check_labels("es_feminine", {1: b"Chromium"}, ids, labels),
                         [f"es_feminine {name} retains an old browser name: Chromium"])

    def test_only_complete_pseudolocale_omission_is_allowed(self):
        ar_pseudo = Path("ar_XB.lproj/locale.pak")
        ar_feminine = Path("ar_XB_FEMININE.lproj/locale.pak")
        en_pseudo = Path("en_XA.lproj/locale.pak")
        ar = Path("ar.lproj/locale.pak")
        de = Path("de.lproj/locale.pak")
        expected = {ar_pseudo, ar_feminine, en_pseudo, ar, de}
        self.assertEqual(missing_installed_packs(expected, {ar, de}), {ar_pseudo, ar_feminine, en_pseudo})
        self.assertEqual(missing_installed_packs(expected, {ar, de}, allow_missing_pseudolocales=True), set())
        self.assertEqual(missing_installed_packs(expected, {ar, ar_pseudo}, allow_missing_pseudolocales=True),
                         {de, ar_feminine})

class PermissionBrandingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import runpy

        repo = Path(__file__).resolve().parents[2]
        recipe = runpy.run_path(str(repo / "Runtime/Chromium/bark/app/rebrand_locales.py"))
        cls.rename = staticmethod(recipe["rebrand_label"])

    def test_capture_preserves_system_setting_and_declension(self):
        name = "IDS_DESKTOP_MEDIA_PICKER_SYSTEM_AUDIO_PERMISSION_TEXT_MAC"
        self.assertEqual(
            self.rename(name, "en-US", "Allow 'System Audio Recording Only' for Chromium. Restart Chromium."),
            "Allow 'System Audio Recording Only' for Bark. Restart Bark.")
        self.assertEqual(self.rename(name, "tr", "Ardından Chromium'u yeniden başlatmanız gerekir."),
                         "Ardından Bark'ı yeniden başlatmanız gerekir.")
        self.assertEqual(self.rename(name, "ko", "그런 다음 Chromium을 다시 시작해야 합니다."),
                         "그런 다음 Bark를 다시 시작해야 합니다.")

    def test_safety_hub_keeps_every_permission_placeholder(self):
        name = "IDS_SETTINGS_SAFETY_HUB_UNUSED_SITE_PERMISSIONS_REMOVED_THREE_PERMISSIONS_LABEL"
        self.assertEqual(self.rename(name, "sl", "Nedavno niste obiskali tega mesta. Chrome je odstranil ta dovoljenja: $1, $2, $3."),
                         "Nedavno niste obiskali tega mesta. Bark je odstranil ta dovoljenja: $1, $2, $3.")
