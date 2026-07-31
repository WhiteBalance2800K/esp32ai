import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class MenuLayoutTests(unittest.TestCase):
    def test_macos_groups_custom_pet_and_quota_settings(self):
        text = (ROOT / "mac-app/Sources/AIClockBridge/MenuBarController.swift").read_text()
        classic = text.index('(\"经典宠物\", \"classic\")')
        collie = text.index('(\"咖色边牧\", \"border-collie\")', classic)
        custom = text.index('makeItem(\"自定义…\", #selector(openPetPicker))', collie)
        separator = text.index('petMenu.addItem(.separator())', custom)

        self.assertLess(classic, collie)
        self.assertLess(collie, custom)
        self.assertLess(custom, separator)
        self.assertIn('petPresetItems["custom"] = customItem', text)
        self.assertIn("displayMenu.addItem(quotaItem)", text)
        self.assertNotIn("menu.addItem(quotaItem)", text)
        self.assertNotIn("更换桌宠动画…（petdex）", text)

    def test_windows_groups_custom_pet_and_quota_settings(self):
        text = (ROOT / "windows-app/AIClockBridge/TrayAppContext.cs").read_text()
        classic = text.index('(\"经典宠物\", \"classic\")')
        collie = text.index('(\"咖色边牧\", \"border-collie\")', classic)
        custom = text.index('MakeItem(\"自定义…\", (_, _) => OpenPetPicker())', collie)
        separator = text.index("petMenu.DropDownItems.Add(new ToolStripSeparator())", custom)

        self.assertLess(classic, collie)
        self.assertLess(collie, custom)
        self.assertLess(custom, separator)
        self.assertIn('_petPresetItems["custom"] = customItem', text)
        self.assertIn("displayMenu.DropDownItems.Add(quotaMenu)", text)
        self.assertNotIn("_menu.Items.Add(quotaMenu)", text)
        self.assertNotIn("更换桌宠动画…（petdex）", text)

    def test_firmware_treats_custom_as_a_switchable_preset(self):
        text = (ROOT / "firmware/src/main.cpp").read_text()
        self.assertIn("enum PetPreset { PET_CLASSIC, PET_BORDER_COLLIE, PET_CUSTOM }", text)
        self.assertIn("return petPreset == PET_CUSTOM &&", text)
        self.assertIn("petPreset = PET_CUSTOM;\n    savePetAppearance();", text)
        self.assertIn("preset must be classic|border-collie|custom", text)


if __name__ == "__main__":
    unittest.main()
