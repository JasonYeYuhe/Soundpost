#!/usr/bin/env python3
"""Is this screenshot the app, or an empty frame?

M19 §4A. The capture script's first version checked only the pixel dimensions, which
a completely black frame satisfies exactly as well as a rendered gallery does — so a
run that photographed the app before it had drawn produced five correctly-sized black
rectangles and reported success. A check that measures the artefact's shape cannot
fail for what is missing from inside it.

This reads the image itself: it downsamples to a small grid and requires the result to
vary. A blank frame has near-zero variance whatever colour it is; a screen with a
navigation bar, cards and text has a great deal. Stdlib only — zlib and struct — so
the release path gains no dependency.
"""
import struct, sys, zlib


def read_png(path):
    """(width, height, [(r,g,b), ...]) for a truecolour or truecolour-alpha PNG."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    pos, idat, width = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour not in (2, 6):
                raise ValueError(f"{path}: depth {depth} colour {colour} unsupported")
            channels = 3 if colour == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(idat)

    stride = width * channels
    pixels, previous = [], bytearray(stride)
    at = 0
    for _ in range(height):
        filter_type = raw[at]; at += 1
        line = bytearray(raw[at:at + stride]); at += stride
        # The five PNG line filters, which are not optional: a screenshot uses Paeth
        # and Up throughout, and skipping them yields noise that passes any variance
        # test — the check would then report "not blank" about garbage.
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = previous[i]
            c = previous[i - channels] if i >= channels else 0
            if filter_type == 1: line[i] = (line[i] + a) & 0xFF
            elif filter_type == 2: line[i] = (line[i] + b) & 0xFF
            elif filter_type == 3: line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        pixels.append(bytes(line))
        previous = line
    return width, height, channels, pixels


def variance(path, grid=8):
    width, height, channels, rows = read_png(path)
    samples = []
    for gy in range(grid):
        for gx in range(grid):
            x = min(width - 1, (gx * 2 + 1) * width // (2 * grid))
            y = min(height - 1, (gy * 2 + 1) * height // (2 * grid))
            row = rows[y]
            r, g, b = row[x * channels], row[x * channels + 1], row[x * channels + 2]
            samples.append((r + g + b) / 3.0)
    mean = sum(samples) / len(samples)
    return sum((s - mean) ** 2 for s in samples) / len(samples), mean


if __name__ == "__main__":
    failures = 0
    for path in sys.argv[1:]:
        var, mean = variance(path)
        # 25 is well below anything a rendered screen produces (the five captured on
        # 2026-09-05 range from ~1,300 to ~9,000) and well above a blank frame's ~0.
        if var < 25:
            print(f"  ✗ {path}: variance {var:.1f}, mean {mean:.0f} — this is an empty frame,"
                  f" not the app", file=sys.stderr)
            failures += 1
    sys.exit(1 if failures else 0)
