import re
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from convert_sprites import load_gif_frames, process_frames, rgb_pixels, to_rgb565  # noqa: E402


class SpriteConversionTests(unittest.TestCase):
    def test_rgb565_is_pre_swapped_for_tft_push_image(self):
        natural = ((0x98 & 0xF8) << 8) | ((0x5A & 0xFC) << 3) | (0x32 >> 3)
        expected = ((natural & 0xFF) << 8) | (natural >> 8)
        self.assertEqual(to_rgb565(0x98, 0x5A, 0x32), expected)

    def test_border_collie_header_matches_source_gif_and_wire_order(self):
        source = ROOT / "firmware/assets/brown-border-collie-states.gif"
        header = ROOT / "firmware/include/img/border_collie_sprite.h"
        frames = process_frames(load_gif_frames(source), 120, 120, max_frames=7)
        text = header.read_text()

        self.assertEqual(len(frames), 7)
        for index, frame in enumerate(frames):
            match = re.search(
                rf"border_collie_sprite_{index}\[14400\] PROGMEM = \{{(.*?)\}};",
                text,
                re.DOTALL,
            )
            self.assertIsNotNone(match, f"missing border collie frame {index}")
            actual = [int(value) for value in re.findall(r"\b\d+\b", match.group(1))]
            expected = [to_rgb565(r, g, b) for r, g, b in rgb_pixels(frame)]
            self.assertEqual(
                actual,
                expected,
                f"frame {index} is not encoded in the TFT panel's RGB565 wire order",
            )


if __name__ == "__main__":
    unittest.main()
