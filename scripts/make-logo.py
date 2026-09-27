#!/usr/bin/env python3
"""Generate the Nyx Linux logo set from geometry, so the artwork is reproducible.

The previous mark was a raster of a third-party character wrapped in SVG. That
is a trademark problem, not a styling preference: the artwork was not ours to
redistribute. The mark here is computed instead, which means it is original, it
scales without artefacts, and anyone can check where it came from by reading
this file.

The shape is a crescent moon, which is what Nyx is. It is drawn as a stack of
horizontal bars rather than a filled path, so it reads as rows of terminal text
and echoes nyx.ascii, the braille wordmark the installer already shows. The
gaps between the bars are the point, not an artefact.

Bar count is the one number that has to be chosen carefully. Densely packed
rows alias: the first attempt used 102 rows in a 512 unit box, which is under
half a pixel per row at the 22 px the installer uses for step icons, and it
turned into noise. At roughly 26 rows the stripes stay legible at 256 px and
merge into an almost solid shape at 22 px, which degrades gracefully instead of
breaking. The large canvases can afford more rows because they are only ever
shown large.

Outputs, all self-contained: Qt treats an external reference as a security risk
and silently draws nothing, so nothing here points outside the file.

  config/logo/nyx-icon.svg                          square, for small places
  config/logo/nyx-mark.svg                          the composition alone
  config/calamares/branding/archlinux/logo.svg      square, installer
  config/calamares/branding/archlinux/logo-wide.svg lockup with the name
  config/calamares/branding/archlinux/welcome.svg   welcome screen
  config/calamares/branding/archlinux/wallpaper.svg 1920x1080 wallpaper

Colours are the slate ramp the rest of the branding already uses, so the mark
sits inside the palette rather than on top of it.
"""

from __future__ import annotations

import math
from pathlib import Path

# Slate ramp, matching the dark branding set.
INK_TOP = "#cbd5e1"
INK_BOTTOM = "#475569"
STAR = "#94a3b8"
CANVAS_TOP = "#0f172a"
CANVAS_BOTTOM = "#020617"
TEXT_MAIN = "#e2e8f0"
TEXT_DIM = "#94a3b8"

MONO = "DejaVu Sans Mono, Liberation Mono, monospace"

PROJECT = Path(__file__).resolve().parent.parent
LOGO_DIR = PROJECT / "config" / "logo"
BRANDING = PROJECT / "config" / "calamares" / "branding" / "archlinux"

# Crescent proportions, relative to the outer radius. The cut disc has to be
# nearly as large as the outer one and offset far enough to leave a slender
# arc. A small offset gives a disc with a bite taken out of it instead.
CUT_DX = 0.46
CUT_DY = -0.36
CUT_R = 0.86

# Row counts, and how much of each row's height is painted. The painted fraction
# is below 1 so the rows read as rows. See the module docstring for why the
# counts are modest.
ROWS_ICON = 26
ROWS_MARK = 30
ROWS_LOCKUP = 28
ROWS_CANVAS = 46
GAP = 0.84


def fmt(value: float) -> str:
    """Format for SVG. A comma decimal separator silently kills coordinates."""
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def crescent_bars(cx: float, cy: float, r: float, rows: int):
    """Return (bars, bar_height): a crescent sliced into horizontal bars.

    The shape is the outer disc with the cut disc removed. On each row the
    surviving run starts at the outer edge and stops where the cut begins, which
    is what gives the taper at both horns.
    """
    bar_h = 2.0 * r / rows
    top = cy - r
    cut_cx = cx + CUT_DX * r
    cut_cy = cy + CUT_DY * r
    cut_r = CUT_R * r
    bars: list[tuple[float, float, float]] = []

    for i in range(rows):
        y_mid = top + (i + 0.5) * bar_h

        dy = y_mid - cy
        if abs(dy) > r:
            continue
        half = math.sqrt(max(0.0, r * r - dy * dy))
        left, right = cx - half, cx + half

        dy = y_mid - cut_cy
        if abs(dy) <= cut_r:
            cut_half = math.sqrt(max(0.0, cut_r * cut_r - dy * dy))
            cut_left = cut_cx - cut_half
            if cut_left < right:
                right = max(left, cut_left)

        width = right - left
        if width > 0.6:
            bars.append((left, top + i * bar_h, width))

    if not bars:
        raise ValueError("crescent produced no bars; check CUT_* placement")
    return bars, bar_h


# Fixed star positions. Constants rather than random, so the output is stable
# and a rebuild produces the same bytes.
STARS = ((0.735, 0.205, 0.030), (0.845, 0.330, 0.019),
         (0.660, 0.395, 0.015), (0.885, 0.145, 0.013))


def defs(*pairs: tuple[str, str, str]) -> str:
    """Linear gradients. ids are explicit so callers never have to guess."""
    out = ["  <defs>"]
    for ident, top, bottom in pairs:
        out.append(
            f'    <linearGradient id="{ident}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bottom}"/></linearGradient>'
        )
    out.append("  </defs>")
    return "\n".join(out)


def emit_mark(bars, bar_h: float, grad: str, opacity: str | None = None) -> list[str]:
    """The crescent as bars. crispEdges keeps each row flush against its
    neighbour, which is what stops the stack turning into a dotted mess."""
    op = f' opacity="{opacity}"' if opacity else ""
    out = [f'  <g id="mark" shape-rendering="crispEdges"{op}>']
    for x, y, w in bars:
        out.append(
            f'    <rect x="{fmt(x)}" y="{fmt(y)}" width="{fmt(w)}" '
            f'height="{fmt(bar_h * GAP)}" fill="url(#{grad})"/>'
        )
    out.append("  </g>")
    return out


def emit_stars(width: float, height: float, scale: float, opacity: str) -> list[str]:
    return [
        f'  <circle cx="{fmt(fx * width)}" cy="{fmt(fy * height)}" '
        f'r="{fmt(fr * scale)}" fill="{STAR}" opacity="{opacity}"/>'
        for fx, fy, fr in STARS
    ]


def svg_open(width: float, height: float) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(width)} '
        f'{fmt(height)}" width="{fmt(width)}" height="{fmt(height)}" '
        f'role="img" aria-label="Nyx Linux">',
        "  <title>Nyx Linux</title>",
    ]


def build_icon(size: int = 512) -> str:
    """Square mark, cropped tight to the crescent."""
    bars, bar_h = crescent_bars(size / 2.0, size / 2.0, size * 0.40, ROWS_ICON)
    out = svg_open(size, size)
    out.append(defs(("ink", INK_TOP, INK_BOTTOM)))
    out += emit_mark(bars, bar_h, "ink")
    out += emit_stars(size, size, size / 512.0, "0.55")
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_mark(width: int = 420, height: int = 420) -> str:
    """The composition alone on a transparent ground."""
    bars, bar_h = crescent_bars(height * 0.50, height * 0.50, height * 0.40,
                                ROWS_MARK)
    out = svg_open(width, height)
    out.append(defs(("ink", INK_TOP, INK_BOTTOM)))
    out += emit_mark(bars, bar_h, "ink")
    out += emit_stars(width, height, height / 420.0, "0.5")
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_logo_wide(width: int = 1200, height: int = 420) -> str:
    """Mark plus the name, for the installer's header."""
    mark_w = int(height * 1.25)
    bars, bar_h = crescent_bars(mark_w / 2.0, height / 2.0, height * 0.38,
                                ROWS_LOCKUP)
    text_x = mark_w + height * 0.22

    out = svg_open(width, height)
    out.append(defs(("ink", INK_TOP, INK_BOTTOM)))
    out += emit_mark(bars, bar_h, "ink")
    out += emit_stars(mark_w, height, height / 420.0, "0.5")
    out.append(
        f'  <text x="{fmt(text_x)}" y="{fmt(height * 0.50)}" fill="{TEXT_MAIN}" '
        f'font-family="{MONO}" font-size="{fmt(height * 0.30)}" font-weight="700" '
        f'letter-spacing="{fmt(height * 0.045)}">NYX</text>'
    )
    out.append(
        f'  <text x="{fmt(text_x + height * 0.04)}" y="{fmt(height * 0.75)}" '
        f'fill="{TEXT_DIM}" font-family="{MONO}" font-size="{fmt(height * 0.13)}" '
        f'letter-spacing="{fmt(height * 0.085)}">LINUX</text>'
    )
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_canvas(width: int, height: int, welcome: bool) -> str:
    """Full-bleed image: the wallpaper, or the welcome screen.

    On the welcome screen the crescent sits high and the text goes below it. The
    first attempt centred both and the name landed on the mark, which is the one
    thing a title screen must not do.
    """
    cy = height * (0.40 if welcome else 0.50)
    bars, bar_h = crescent_bars(width * 0.5, cy, height * 0.30, ROWS_CANVAS)

    out = svg_open(width, height)
    out.append(defs(("bg", CANVAS_TOP, CANVAS_BOTTOM),
                    ("ink", INK_TOP, INK_BOTTOM)))
    out.append(f'  <rect width="{fmt(width)}" height="{fmt(height)}" fill="url(#bg)"/>')

    # A scatter of dimmer stars behind, so the crescent is not alone on the sky.
    for fx, fy, fr in STARS:
        out.append(
            f'  <circle cx="{fmt(fx * width * 1.7)}" cy="{fmt(fy * height * 0.85)}" '
            f'r="{fmt(fr * height * 0.0030)}" fill="{STAR}" opacity="0.22"/>'
        )
    out += emit_stars(width, height, height * 0.0032, "0.42")
    out += emit_mark(bars, bar_h, "ink", opacity="0.18")

    if welcome:
        out.append(
            f'  <text x="{fmt(width * 0.5)}" y="{fmt(height * 0.80)}" '
            f'fill="{TEXT_MAIN}" font-family="{MONO}" font-size="{fmt(height * 0.085)}" '
            f'font-weight="700" text-anchor="middle" '
            f'letter-spacing="{fmt(height * 0.024)}">NYX LINUX</text>'
        )
        out.append(
            f'  <text x="{fmt(width * 0.5)}" y="{fmt(height * 0.875)}" '
            f'fill="{TEXT_DIM}" font-family="{MONO}" font-size="{fmt(height * 0.032)}" '
            f'text-anchor="middle" letter-spacing="{fmt(height * 0.010)}">'
            f"UEFI and GPT, and no other boot mode</text>"
        )
    out.append("</svg>")
    return "\n".join(out) + "\n"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"  {path.relative_to(PROJECT)}  {path.stat().st_size} bytes")


def main() -> int:
    print("generating the logo set")
    write(LOGO_DIR / "nyx-icon.svg", build_icon())
    write(LOGO_DIR / "nyx-mark.svg", build_mark())
    write(BRANDING / "logo.svg", build_icon())
    write(BRANDING / "logo-wide.svg", build_logo_wide())
    write(BRANDING / "welcome.svg", build_canvas(1920, 1080, True))
    write(BRANDING / "wallpaper.svg", build_canvas(1920, 1080, False))
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
