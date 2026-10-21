#!/usr/bin/env python3
"""Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.

The artwork is centred on a warm off-white rounded-square tile laid out on Apple's macOS icon
grid (an 824x824 tile inset 100 px on a 1024 canvas, with a soft shadow). The .icns is written
directly with PNG chunks, so no Apple tools are needed. Also writes previews to build/:
icon-preview.png (the app icon) and menubar-preview.png (the menu bar icon on light and dark
menu bars).

Requires: pip install cairosvg pillow
Usage:    python3 scripts/make-icons.py
"""

import io
import struct
from pathlib import Path

import cairosvg
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
BUILD = ROOT / "build"

CANVAS = 1024
TILE_INSET = 100
TILE_RADIUS = 185
TILE_TOP = (0xFF, 0xF6, 0xEC)
TILE_BOTTOM = (0xFC, 0xEB, 0xD9)
ARTWORK_HEIGHT = 0.70  # fraction of the tile height

# (type, pixel size) for every image macOS looks for in an .icns.
ICNS_ENTRIES = [
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256),
    (b"ic09", 512), (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]


def render_svg(path: Path, width: int) -> Image.Image:
    png = cairosvg.svg2png(url=str(path), output_width=width, output_height=width)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def rounded_mask(size: int, inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, size - inset - 1, size - inset - 1), radius, fill=255)
    return mask


def app_icon() -> Image.Image:
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mask = rounded_mask(CANVAS, TILE_INSET, TILE_RADIUS)

    # Soft drop shadow beneath the tile.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_alpha = mask.point(lambda value: value * 0.28).filter(ImageFilter.GaussianBlur(18))
    shadow.putalpha(ImageChops.offset(shadow_alpha, 0, 12))
    icon = Image.alpha_composite(icon, shadow)

    # Tile with a gentle vertical gradient.
    gradient = Image.new("RGBA", (CANVAS, CANVAS))
    draw = ImageDraw.Draw(gradient)
    for y in range(CANVAS):
        t = min(1, max(0, (y - TILE_INSET) / (CANVAS - 2 * TILE_INSET)))
        draw.line([(0, y), (CANVAS, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TILE_TOP, TILE_BOTTOM)) + (255,))
    tile = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    tile.paste(gradient, mask=mask)
    icon = Image.alpha_composite(icon, tile)

    # Hairline edge.
    edge = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (TILE_INSET, TILE_INSET, CANVAS - TILE_INSET - 1, CANVAS - TILE_INSET - 1), TILE_RADIUS,
        outline=(0, 0, 0, 20), width=2,
    )
    icon = Image.alpha_composite(icon, edge)

    # Artwork, cropped to its visible bounds and centred on the tile.
    artwork = render_svg(RESOURCES / "AppIcon.svg", 4096)
    artwork = artwork.crop(artwork.getchannel("A").getbbox())
    target_height = round((CANVAS - 2 * TILE_INSET) * ARTWORK_HEIGHT)
    target_width = round(artwork.width * target_height / artwork.height)
    artwork = artwork.resize((target_width, target_height), Image.LANCZOS)
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(artwork, ((CANVAS - target_width) // 2, (CANVAS - target_height) // 2), artwork)
    return Image.alpha_composite(icon, layer)


def write_icns(icon: Image.Image, path: Path) -> None:
    chunks = b""
    for kind, size in ICNS_ENTRIES:
        buffer = io.BytesIO()
        icon.resize((size, size), Image.LANCZOS).save(buffer, format="PNG", optimize=True)
        data = buffer.getvalue()
        chunks += kind + struct.pack(">I", len(data) + 8) + data
    path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


def menubar_preview(path: Path) -> None:
    """Approximates the template image the app draws: dark shapes filled, white shapes cut out."""
    source = (RESOURCES / "MenuBarIcon.svg").read_text()
    strips = []
    for background, foreground in (("#ECECEC", "#000000"), ("#2A2A2A", "#FFFFFF")):
        svg = source.replace("#122035", foreground).replace("#FEFDFD", background)
        strip = Image.new("RGBA", (220, 88), background)
        glyph = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=144, output_height=144))).convert("RGBA")
        small = glyph.resize((44, 44), Image.LANCZOS)
        large = glyph.resize((72, 72), Image.LANCZOS)
        strip.alpha_composite(small, (24, 22))
        strip.alpha_composite(large, (120, 8))
        strips.append(strip)
    preview = Image.new("RGBA", (220, 176))
    preview.paste(strips[0], (0, 0))
    preview.paste(strips[1], (0, 88))
    preview.save(path)


def main() -> None:
    BUILD.mkdir(exist_ok=True)
    icon = app_icon()
    write_icns(icon, RESOURCES / "AppIcon.icns")
    sizes = (128, 64, 32)
    preview = Image.new("RGBA", (CANVAS + sum(sizes) + 24 * (len(sizes) + 1), CANVAS), (255, 255, 255, 0))
    preview.paste(icon, (0, 0))
    x = CANVAS + 24
    for size in sizes:
        small = icon.resize((size, size), Image.LANCZOS)
        preview.paste(small, (x, 40), small)
        x += size + 24
    preview.save(BUILD / "icon-preview.png")
    menubar_preview(BUILD / "menubar-preview.png")
    print(f"Wrote {RESOURCES / 'AppIcon.icns'} and previews in {BUILD}")


if __name__ == "__main__":
    main()
