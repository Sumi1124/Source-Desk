#!/usr/bin/env python3
"""Generate the SourceDesk app icon.

    python3 scripts/generate_icon.py

Writes:
  docs/icon.png                     1024x1024, for the README
  Assets/AppIcon.icns               the macOS icon
  Assets/AppIcon.iconset/*.png      the sizes iTunes/`iconutil` expect

The design is deliberately restrained, matching the application's own visual
language: a single soft slate field, a document, and three citation marks. No
gradient mesh, no glow, nothing that needs a caption.

Pure standard library — no Pillow, no ImageMagick — so it runs anywhere Python 3
does, including a fresh checkout on a Mac that has never installed anything.
"""

import math
import os
import struct
import subprocess
import sys
import zlib

SIZE = 1024
SUPERSAMPLE = 2

# Palette (kept in step with Sources/SourceDesk/Views/Design.swift).
FIELD_TOP = (0x1F, 0x2A, 0x3A)
FIELD_BOTTOM = (0x14, 0x1B, 0x26)
PAPER = (0xFA, 0xFA, 0xF8)
PAPER_EDGE = (0xDF, 0xDF, 0xDA)
INK = (0x24, 0x2B, 0x36)
INK_SOFT = (0x6B, 0x74, 0x82)
ACCENT = (0x2F, 0x6F, 0xE0)      # the citation blue used in the app
ACCENT_2 = (0x2E, 0x8B, 0x74)    # the second citation tint
MARK_DIM = (0xC7, 0xCE, 0xD8)


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(lerp(c1[i], c2[i], t) for i in range(3))


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def inside_rounded_rect(px, py, x0, y0, x1, y1, radius):
    """Point-in-rounded-rectangle test (exact, not an approximation)."""
    cx = clamp(px, x0 + radius, x1 - radius)
    cy = clamp(py, y0 + radius, y1 - radius)
    dx = px - cx
    dy = py - cy
    if dx == 0 and dy == 0:
        return True
    # Only the corner regions can be outside.
    if x0 <= px <= x1 and y0 <= py <= y1:
        if radius <= 0:
            return True
        if x0 + radius <= px <= x1 - radius or y0 + radius <= py <= y1 - radius:
            return True
    return dx * dx + dy * dy <= radius * radius


def write_png(path, width, height, pixels):
    """Minimal PNG writer: 8-bit RGBA, no interlacing."""
    def chunk(tag, data):
        payload = tag + data
        return (struct.pack(">I", len(data)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: none
        row = pixels[y * width:(y + 1) * width]
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", header)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def draw():
    """Render at SUPERSAMPLE times the size, then box-downsample for clean edges."""
    scale = SUPERSAMPLE
    dimension = SIZE * scale
    radius = dimension * 0.225               # macOS-style squircle-ish corner
    margin = dimension * 0.0

    # Geometry, all as fractions of the canvas.
    paper_x0, paper_y0 = dimension * 0.235, dimension * 0.180
    paper_x1, paper_y1 = dimension * 0.765, dimension * 0.830
    paper_radius = dimension * 0.045

    # Three citation chips inside the paper's right margin, so they read as inline
    # citations rather than bleeding off the page.
    marks = [
        (0.500, ACCENT),
        (0.640, ACCENT_2),
        (0.780, MARK_DIM),
    ]

    # Text lines inside the paper: (y fraction, width fraction).
    # Text lines. Widths are capped so the citation chips keep clear space.
    lines = [
        (0.250, 0.60), (0.325, 0.62), (0.400, 0.62),
        (0.475, 0.42), (0.585, 0.62), (0.660, 0.50),
        (0.735, 0.34),
    ]

    pixels = [None] * (dimension * dimension)
    line_half = dimension * 0.017

    for y in range(dimension):
        vertical = y / dimension
        field = mix(FIELD_TOP, FIELD_BOTTOM, vertical)

        for x in range(dimension):
            r, g, b = field
            # macOS masks icons to a rounded square; drawing it here means the PNG
            # looks correct in the README and in any non-macOS viewer too.
            if not inside_rounded_rect(x, y, margin, margin,
                                       dimension - margin, dimension - margin, radius):
                pixels[y * dimension + x] = (0, 0, 0, 0)
                continue
            alpha = 255

            # Paper: a very slight vertical lightening keeps it from looking flat
            # without being a decorative gradient.
            if inside_rounded_rect(x, y, paper_x0, paper_y0, paper_x1, paper_y1, paper_radius):
                paper_t = (y - paper_y0) / (paper_y1 - paper_y0)
                r, g, b = mix(PAPER, PAPER_EDGE, paper_t * 0.35)

                # Accent rule near the top, echoing the app's section headers.
                if paper_y0 + dimension * 0.075 <= y <= paper_y0 + dimension * 0.095:
                    if paper_x0 + dimension * 0.075 <= x <= paper_x0 + dimension * 0.255:
                        r, g, b = ACCENT

                # Text lines.
                for line_y, line_w in lines:
                    yy = paper_y0 + line_y * (paper_y1 - paper_y0)
                    if abs(y - yy) <= line_half:
                        lx0 = paper_x0 + dimension * 0.075
                        lx1 = lx0 + (paper_x1 - paper_x0 - dimension * 0.150) * line_w
                        if lx0 <= x <= lx1:
                            r, g, b = INK_SOFT
                            break

                # Citation chips sit inside the paper's right margin.
                for mark_y, colour in marks:
                    yy = paper_y0 + mark_y * (paper_y1 - paper_y0)
                    if abs(y - yy) <= dimension * 0.022:
                        mx1 = paper_x1 - dimension * 0.075
                        mx0 = mx1 - dimension * 0.105
                        if mx0 <= x <= mx1:
                            r, g, b = colour
                            break

            pixels[y * dimension + x] = (
                int(clamp(r, 0, 255)), int(clamp(g, 0, 255)), int(clamp(b, 0, 255)), alpha
            )

    # Box downsample.
    out = []
    n = scale * scale
    for y in range(SIZE):
        for x in range(SIZE):
            rs = gs = bs = 0
            base_row = (y * scale) * dimension
            for dy in range(scale):
                offset = base_row + dy * dimension + x * scale
                for dx in range(scale):
                    r0, g0, b0, _ = pixels[offset + dx]
                    rs += r0
                    gs += g0
                    bs += b0
            out.append((rs // n, gs // n, bs // n, 255))
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    docs_dir = os.path.join(root, "docs")
    assets_dir = os.path.join(root, "Assets")
    iconset_dir = os.path.join(assets_dir, "AppIcon.iconset")
    os.makedirs(docs_dir, exist_ok=True)
    os.makedirs(iconset_dir, exist_ok=True)

    pixels = draw()

    master = os.path.join(assets_dir, "AppIcon-1024.png")
    write_png(master, SIZE, SIZE, pixels)
    print("wrote", os.path.relpath(master, root))

    readme_icon = os.path.join(docs_dir, "icon.png")
    write_png(readme_icon, SIZE, SIZE, pixels)
    print("wrote", os.path.relpath(readme_icon, root))

    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, size in sizes.items():
        destination = os.path.join(iconset_dir, name)
        result = subprocess.run(
            ["sips", "-z", str(size), str(size), master, "--out", destination],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
        )
        if result.returncode != 0:
            print(f"  ! could not write {name} (sips is macOS-only)", file=sys.stderr)

    icns = os.path.join(assets_dir, "AppIcon.icns")
    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
    )
    if result.returncode == 0:
        print("wrote", os.path.relpath(icns, root))
    else:
        print("  ! iconutil is unavailable; the .iconset is still complete", file=sys.stderr)


if __name__ == "__main__":
    main()
