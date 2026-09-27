#!/usr/bin/env python3
"""Generate the Nyx Linux logo set from geometry, so the artwork is reproducible.

The previous mark was a raster of a third-party character wrapped in SVG. That
is a trademark problem, not a styling preference: the artwork was not ours to
redistribute. The mark here is computed instead, which means it is original, it
scales without artefacts, and anyone can check where it came from by reading this
file.

The shape is a crescent moon, which is what Nyx is. It is drawn as a single
filled path, and the row texture that ties it to the terminal is applied on top
as thin lines clipped to that path.

Building the silhouette out of rows instead was tried first and failed twice,
both times for the same reason: the silhouette and the texture are different
problems, and tying them to one number cannot satisfy both. With 102 rows the
icon was noise at 22 px. With 26 rows it was clean in a browser and still
looked like a blob in the installer header, which draws the lockup smaller than
anything that had been checked. With 12 rows the stripes survived but the outer
edge became a staircase. A path has no such coupling: it stays smooth at every
size, and the stripes fade to a tint rather than destroying the shape.

Outputs, all self-contained. Qt treats an external reference as a security risk
and silently draws nothing, so nothing here points outside the file, and the
crescent path is written out twice rather than pulled in through <use>, which
some minimal renderers resolve differently.

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
STRIPE = "#0f172a"
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
# nearly as large as the outer one and offset far enough to leave a slender arc.
CUT_DX = 0.46
CUT_DY = -0.36
CUT_R = 0.86

# Texture. STRIPES is how many lines cross the mark; it is purely decorative and
# degrades to a tint when the mark is small. STRIPE_WEIGHT is their thickness as
# a fraction of the spacing, so the proportion holds at any scale.
STRIPES = 11
STRIPE_WEIGHT = 0.30

# Fixed star positions. Constants rather than random, so the output is stable
# and a rebuild produces the same bytes.
STARS = ((0.735, 0.205, 0.030), (0.845, 0.330, 0.019),
         (0.660, 0.395, 0.015), (0.885, 0.145, 0.013))


def fmt(value: float) -> str:
    """Format for SVG. A comma decimal separator silently kills coordinates."""
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def _arc(cx: float, cy: float, r: float, a_from: float, a_to: float,
         a_through: float, steps: int) -> list[tuple[float, float]]:
    """Sample an arc from a_from to a_to travelling the way that passes through
    a_through.

    The direction cannot be assumed: both arcs of a crescent bulge towards the
    side away from the cut, so it depends on where the intersection points fell.
    Guessing it is what produced a shape with straight chords instead of curves.
    """
    tau = 2.0 * math.pi
    reach = (a_to - a_from) % tau
    via = (a_through - a_from) % tau
    direction = 1 if via <= reach else -1
    sweep = reach if direction > 0 else -(tau - reach)

    return [
        (cx + r * math.cos(a_from + sweep * (i / steps)),
         cy + r * math.sin(a_from + sweep * (i / steps)))
        for i in range(steps + 1)
    ]


def crescent_path(cx: float, cy: float, r: float, steps: int = 96) -> str:
    """A crescent as an explicit polygon: the outer arc, then the cut arc back.

    Polygon rather than elliptical arc commands on purpose. Arc flags are
    ambiguous here and Qt's renderer, which the installer uses, is not forgiving
    about them; with the flags set one way the shape came out with straight
    chords. A polygon renders identically everywhere, and at this step count
    the facets are invisible.
    """
    cut_x = cx + CUT_DX * r
    cut_y = cy + CUT_DY * r
    cut_r = CUT_R * r

    dx, dy = cut_x - cx, cut_y - cy
    dist = math.hypot(dx, dy)
    if dist >= r + cut_r or dist <= abs(r - cut_r):
        raise ValueError("crescent placement is degenerate: the discs do not overlap")

    a = (r * r - cut_r * cut_r + dist * dist) / (2.0 * dist)
    h = math.sqrt(max(0.0, r * r - a * a))

    ux, uy = dx / dist, dy / dist
    mx, my = cx + a * ux, cy + a * uy
    p1 = (mx - h * uy, my + h * ux)
    p2 = (mx + h * uy, my - h * ux)
    away = math.atan2(-uy, -ux)

    outer = _arc(cx, cy, r,
                 math.atan2(p1[1] - cy, p1[0] - cx),
                 math.atan2(p2[1] - cy, p2[0] - cx), away, steps)
    inner = _arc(cut_x, cut_y, cut_r,
                 math.atan2(p2[1] - cut_y, p2[0] - cut_x),
                 math.atan2(p1[1] - cut_y, p1[0] - cut_x), away, steps)

    pts = outer + inner[1:]
    head = f"M {fmt(pts[0][0])} {fmt(pts[0][1])}"
    rest = " ".join(f"L {fmt(px)} {fmt(py)}" for px, py in pts[1:])
    return f"{head} {rest} Z"


def defs(gradients, clip_id: str | None = None, clip_d: str | None = None) -> str:
    out = ["  <defs>"]
    for ident, top, bottom in gradients:
        out.append(
            f'    <linearGradient id="{ident}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bottom}"/></linearGradient>'
        )
    if clip_id and clip_d:
        # The path is repeated rather than referenced with <use>: some minimal
        # renderers resolve same-document references differently, and a clip
        # that silently fails leaves an unmarked shape, which looks like a
        # different design rather than a failure.
        out.append(f'    <clipPath id="{clip_id}"><path d="{clip_d}"/></clipPath>')
    out.append("  </defs>")
    return "\n".join(out)


def emit_stripes(clip_id: str, cx: float, cy: float, r: float,
                 width: float, count: int) -> list[str]:
    """Thin lines across the mark, clipped to it. This is the row texture."""
    span = 2.0 * r * 0.88
    step = span / count
    weight = step * STRIPE_WEIGHT
    top = cy - r * 0.92
    out = [f'  <g clip-path="url(#{clip_id})" fill="none" stroke="{STRIPE}"'
           f' stroke-width="{fmt(weight)}" stroke-linecap="butt"'
           f' opacity="0.55">']
    for i in range(count):
        y = top + i * step
        out.append(f'    <line x1="{fmt(cx - r)}" y1="{fmt(y)}"'
                   f' x2="{fmt(cx + r)}" y2="{fmt(y)}"/>')
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
    r = size * 0.40
    d = crescent_path(size / 2.0, size / 2.0, r)
    out = svg_open(size, size)
    out.append(defs([("ink", INK_TOP, INK_BOTTOM)], "crescent", d))
    out.append(f'  <path d="{d}" fill="url(#ink)"/>')
    out += emit_stripes("crescent", size / 2.0, size / 2.0, r, size, STRIPES)
    out += emit_stars(size, size, size / 512.0, "0.55")
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_mark(width: int = 420, height: int = 420) -> str:
    """The composition alone on a transparent ground."""
    r = height * 0.40
    d = crescent_path(height * 0.50, height * 0.50, r)
    out = svg_open(width, height)
    out.append(defs([("ink", INK_TOP, INK_BOTTOM)], "crescent", d))
    out.append(f'  <path d="{d}" fill="url(#ink)"/>')
    out += emit_stripes("crescent", height * 0.50, height * 0.50, r, width, STRIPES)
    out += emit_stars(width, height, height / 420.0, "0.5")
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_logo_wide(width: int = 1200, height: int = 420) -> str:
    """Mark plus the name, for the installer's header."""
    mark_w = int(height * 1.25)
    cx, cy, r = mark_w / 2.0, height / 2.0, height * 0.38
    d = crescent_path(cx, cy, r)
    text_x = mark_w + height * 0.22

    out = svg_open(width, height)
    out.append(defs([("ink", INK_TOP, INK_BOTTOM)], "crescent", d))
    out.append(f'  <path d="{d}" fill="url(#ink)"/>')
    out += emit_stripes("crescent", cx, cy, r, mark_w, STRIPES)
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
    r = height * 0.30
    d = crescent_path(width * 0.5, cy, r)

    out = svg_open(width, height)
    out.append(defs([("bg", CANVAS_TOP, CANVAS_BOTTOM),
                     ("ink", INK_TOP, INK_BOTTOM)], "crescent", d))
    out.append(f'  <rect width="{fmt(width)}" height="{fmt(height)}" fill="url(#bg)"/>')

    # A scatter of dimmer stars behind, so the crescent is not alone on the sky.
    for fx, fy, fr in STARS:
        out.append(
            f'  <circle cx="{fmt(fx * width * 1.7)}" cy="{fmt(fy * height * 0.85)}" '
            f'r="{fmt(fr * height * 0.0030)}" fill="{STAR}" opacity="0.22"/>'
        )
    out += emit_stars(width, height, height * 0.0032, "0.42")

    out.append(f'  <g opacity="0.18"><path d="{d}" fill="url(#ink)"/>')
    out += emit_stripes("crescent", width * 0.5, cy, r, width, STRIPES)
    out.append("  </g>")

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
