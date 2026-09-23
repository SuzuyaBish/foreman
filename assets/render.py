#!/usr/bin/env python3
"""Render foreman's title card at either committed size.

One composition, two committed outputs, one tagline:

    python3 assets/render.py banner        # assets/banner.png          2560x1280
    python3 assets/render.py banner 2048   # any even width; height is width / 2
    python3 assets/render.py card          # assets/social-preview.png  1280x640

The README banner and the GitHub social-preview card are the same title card --
the FOREMAN wordmark over the public-domain Gray's fig. 557 head plate -- drawn
at two sizes. They are folded into one recipe on purpose: they had drifted before
(the banner read a shortened tagline the captain never chose), and with a single
`TAGLINE` constant they cannot drift in wording again. The card's size is fixed
at 1280x640; the banner takes any even width so the README can ask for extra
resolution.

It is deliberately offline: it reads the plate from this directory and never
touches the network. Run it from the repo root or anywhere else.

Plate source and licence
------------------------
  File:  Gray AnatomyOfHumanBody1918-P644 Figure557.jpg
  Page:  https://commons.wikimedia.org/wiki/File:Gray_AnatomyOfHumanBody1918-P644_Figure557.jpg
  Work:  Henry Gray, "Anatomy of the Human Body" (1918), fig. 557;
         drawing by Henry Vandyke Carter
  Licence: Public domain (published 1918; author died 1861, PD worldwide).
  Local copy: assets/gray-fig557.jpg (1788x2118).

The artwork is public domain, so both outputs and the plate may be
redistributed. No show logo, stills, likenesses or show fonts are used; the type
is rendered from the same system fonts as the social card.

Why the banner is 2560 px wide
------------------------------
GitHub's markdown column is ~1012 CSS px. On a 2x display that is ~2024 device
pixels, so a 1280 px card is upscaled. 2560 gives ~2.5x and headroom. The plate
puts the head at 1.18 * canvas height, so a 1280-tall banner needs a 1510 px head
from a 2118 px plate: the plate is still being downscaled (~0.71x), so the banner
is not upscaled anywhere.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
PLATE = os.path.join(HERE, "gray-fig557.jpg")
BANNER = os.path.join(HERE, "banner.png")
CARD = os.path.join(HERE, "social-preview.png")

# The captain's line, verbatim. Both outputs draw exactly this string.
TAGLINE = "I don't treat. I diagnose, then hand the case to the crew."

# Base design is the 1280x640 card; every dimension scales from it.
BASE_W, BASE_H = 1280, 640
HEAD_RATIO = 1.18  # head plate height as a multiple of the canvas height
TAG_SIZE = 20      # mono px for the tagline, at the 1280-wide base design

BG = (9, 10, 12)
INK = (236, 232, 225)
GREY = (168, 165, 158)
DIM = (112, 110, 104)
RED = (198, 34, 40)
FOOT = (90, 88, 84)

SERIF_B = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(path, size):
    return ImageFont.truetype(path, int(round(size)))


def duotone(im, color=INK, gamma=1.0, cutoff=1, invert=True):
    """Dark ink becomes `color`, paper becomes transparent."""
    g = ImageOps.grayscale(im)
    g = ImageOps.autocontrast(g, cutoff=cutoff)
    if invert:
        g = ImageOps.invert(g)
    if gamma != 1.0:
        g = g.point(lambda v: int(255 * ((v / 255.0) ** gamma)))
    rgba = Image.new("RGBA", im.size, color + (0,))
    rgba.putalpha(g)
    return rgba


def bg_canvas(w, h, s):
    c = Image.new("RGB", (w, h), BG)
    step = max(1, int(round(64 * s)))
    g = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    for x in range(0, w, step):
        d.line([(x, 0), (x, h)], fill=(255, 255, 255, 7))
    for y in range(0, h, step):
        d.line([(0, y), (w, y)], fill=(255, 255, 255, 7))
    c = Image.alpha_composite(c.convert("RGBA"), g).convert("RGB")
    v = Image.radial_gradient("L").resize((w, h))
    v = ImageOps.invert(v)
    dark = Image.new("RGB", (w, h), (0, 0, 0))
    c = Image.composite(c, dark, v.point(lambda x: 150 + x * 105 // 255))
    return c.convert("RGBA")


def tracked(draw, xy, text, fnt, fill, tracking=0):
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + tracking
    return x


def tag_metrics(width, tagline=TAGLINE, tag_size=TAG_SIZE):
    """Where the tagline lands at `width`: (start x, rendered width, end x, font px)."""
    s = (width // 2) / BASE_H
    f = font(MONO, tag_size * s)
    draw = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    x = int(76 * s)
    w = draw.textlength(tagline, font=f)
    return x, w, x + w, f.size


def render(width=2560, tagline=TAGLINE, tag_size=TAG_SIZE):
    """The title-card composition, at `width` px (height = width / 2)."""
    width = int(width)
    height = width // 2
    s = height / BASE_H  # scale from the 640-tall base design

    c = bg_canvas(width, height, s)

    head = Image.open(PLATE)
    head = duotone(head, INK, gamma=0.92, cutoff=2).resize(
        (int(head.width * (height * HEAD_RATIO) / head.height),
         int(height * HEAD_RATIO)), Image.LANCZOS)
    c.alpha_composite(head, (width - head.width + int(170 * s), int(-60 * s)))

    d = ImageDraw.Draw(c)
    x = int(76 * s)
    f_top = font(MONO, 20 * s)
    f_word = font(SERIF_B, 104 * s)
    f_tag = font(MONO, tag_size * s)
    track = 2 * s
    d.text((x, int(150 * s)), "// a captain -> foreman -> crew harness",
           font=f_top, fill=DIM)
    y = int(196 * s)
    tracked(d, (x, y), "FOREMAN", f_word, INK, tracking=track)
    d.line([(x, int(324 * s)), (x + int(300 * s), int(324 * s))],
           fill=RED, width=max(1, int(round(3 * s))))
    d.text((x, int(346 * s)), tagline, font=f_tag, fill=GREY)
    d.text((x, height - int(60 * s)),
           "parallel crew . isolated worktrees . flat context", font=font(MONO, 17 * s),
           fill=FOOT)
    return c.convert("RGB")


def save_optimized(im, path):
    """Palette-quantize the duotone artwork: same look, far fewer bytes."""
    pal = im.convert("RGB").quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
    pal.save(path, "PNG", optimize=True)


def _emit(im, path, tagline, tag_size, width):
    x0, tw, x1, fpx = tag_metrics(width, tagline, tag_size)
    save_optimized(im, path)
    print(f"wrote {path} {im.width}x{im.height}; "
          f"tagline {fpx}px mono, x {x0}..{x1} ({tw:.1f}px wide)")


def main(argv):
    target = argv[1] if len(argv) > 1 else "banner"
    if target == "banner":
        width = int(argv[2]) if len(argv) > 2 else 2560
        im = render(width)
        _emit(im, BANNER, TAGLINE, TAG_SIZE, width)
        return 0
    if target == "card":
        im = render(BASE_W)
        _emit(im, CARD, TAGLINE, TAG_SIZE, BASE_W)
        return 0
    sys.stderr.write(f"unknown target: {target!r}\n")
    sys.stderr.write("usage: render.py banner [width] | card\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
