"""The capture's blank-frame check sees a light screen as drawn (M23 S6).

`screenshot_check.py` sampled an 8 × 8 grid of single pixels. On the zh-Hans search
result every one of the 64 landed between the strokes and the screen — four cards of
waveforms and text — was rejected as blank twenty times running. These fixtures are
built so that the old grid sees nothing and the screen is plainly not blank: white,
with dark bars that sit between the 8 × 8 rows. Standard library only.
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import screenshot_check  # noqa: E402

WIDTH, HEIGHT = 320, 640


def write_png(path, pixel):
    """An 8-bit RGB PNG, unfiltered rows; `pixel(x, y)` gives the grey level."""
    raw = b"".join(b"\x00" + bytes(v for x in range(WIDTH) for v in (pixel(x, y),) * 3)
                   for y in range(HEIGHT))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw)))
        f.write(chunk(b"IEND", b""))


def rows_of(grid):
    return {(2 * g + 1) * HEIGHT // (2 * grid) for g in range(grid)}


def between_the_old_rows(x, y):
    """Bars 20 px tall, one every 80 px, each between two of the 8 × 8 grid's rows."""
    return 40 if 10 <= x < WIDTH - 10 and 50 <= y % 80 < 70 else 255


class ScreenshotCheckTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def png(self, name, pixel):
        path = os.path.join(self.dir, name)
        write_png(path, pixel)
        return path

    def check(self, path):
        return subprocess.run([sys.executable, os.path.join(HERE, "screenshot_check.py"), path],
                              capture_output=True, text=True)

    def test_the_fixture_is_one_the_old_grid_could_not_see(self):
        # Proves the fixture, not the checker: every bar misses the 8 × 8 rows.
        bars = {y for y in range(HEIGHT) if between_the_old_rows(WIDTH // 2, y) < 255}
        self.assertTrue(bars)
        self.assertFalse(bars & rows_of(8))
        self.assertEqual(screenshot_check.variance(self.png("bars.png", between_the_old_rows), grid=8)[0], 0)

    def test_a_light_screen_with_thin_content_is_not_blank(self):
        path = self.png("bars.png", between_the_old_rows)
        var, _ = screenshot_check.variance(path)
        self.assertGreater(var, 25, "the default grid misses content between its rows")
        self.assertEqual(self.check(path).returncode, 0)

    def test_a_blank_frame_is_still_refused(self):
        for level in (0, 255, 128):
            with self.subTest(level=level):
                path = self.png(f"blank-{level}.png", lambda x, y: level)
                self.assertEqual(screenshot_check.variance(path)[0], 0)
                result = self.check(path)
                self.assertEqual(result.returncode, 1)
                self.assertIn("empty frame", result.stderr)


if __name__ == "__main__":
    unittest.main()
