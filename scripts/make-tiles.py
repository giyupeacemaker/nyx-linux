#!/usr/bin/env python3
"""Generate the installer preview tiles.

These are not screenshots. Nobody can screenshot nineteen desktops here, and a
picture of a KDE session next to a picture of an i3 session would be nineteen
installations' worth of work for artwork that goes stale the moment a release
moves. What each tile shows is the layout, because for a tiling compositor the
layout is the thing you are actually choosing: five columns that scroll is niri,
a split with gaps is hyprland, a tree is sway, one pane and a status bar is i3.

The tiles carry no text at all, on purpose.

The first version put a title, a caption and a monospace hint inside the tile.
That was wrong twice over. Real screenshots are not captioned either, so the
captions made these look like diagrams trying to be photographs, and, worse, they
put text in the artwork whose contrast had nothing to do with the installer
theme. Calamares draws the name of every choice itself, in its own font, in its
own colours, where the contrast is already taken care of. Anything the tile says
duplicates that badly. A layout sketch with no words in it is both more honest
and one less thing that can come out unreadable.

The plates are light, for the same reason stock installer screenshots are: they
read as a picture of a desktop rather than as a swatch.

No animation. QtSvg, which draws these inside Calamares, does not animate SMIL or
CSS, so an animated file would only ever show its first frame.

Run:  python3 scripts/make-tiles.py
"""

from __future__ import annotations

import pathlib

PROJECT = pathlib.Path(__file__).resolve().parent.parent
BRANDING = PROJECT / "config" / "calamares" / "branding" / "archlinux"

W, H = 480, 270
RADIUS = 18

# Light plate, light chrome, and one accent per desktop. Every colour here has to
# stay legible against #f1f5f9, which is the opposite constraint from the dark
# version this replaced, so the accents are mid-tone rather than neon.
PLATE_TOP, PLATE_BOTTOM, EDGE = "#ffffff", "#f1f5f9", "#cbd5e1"
BAR = "#e2e8f0"
CARD = "#ffffff"
INK = "#94a3b8"

PALETTE: dict[str, str] = {
    "kde": "#2563eb",
    "gnome": "#b45309",
    "xfce": "#15803d",
    "mate": "#4d7c0f",
    "cinnamon": "#c2410c",
    "budgie": "#0369a1",
    "lxqt": "#475569",
    "deepin": "#1d4ed8",
    "enlightenment": "#7e22ce",
    "pantheon": "#047857",
    "sway": "#0369a1",
    "hyprland": "#2563eb",
    "hyprland-noctalia": "#2563eb",
    "hyprland-dms": "#0284c7",
    "niri": "#0f766e",
    "niri-noctalia": "#0f766e",
    "niri-dms": "#0d9488",
    "i3": "#a16207",
    "minimal": "#334155",
    # The fallback plate, for a module that wants a picture without naming a
    # choice. It was the tile thirteen desktops used before each of them had its
    # own, and it was left behind dark and captioned, which is now the one thing
    # the rest of the set must not be. Regenerating it keeps a spare without
    # putting a file that contradicts the design back into the tree.
    "generic": "#64748b",
}

# id -> the layout sketch to draw
SKETCH: dict[str, str] = {
    "kde": "full",
    "gnome": "full",
    "xfce": "panel-top",
    "mate": "panel-bottom",
    "cinnamon": "panel-bottom",
    "budgie": "dock",
    "lxqt": "panel-bottom",
    "deepin": "dock",
    "enlightenment": "panel-top",
    "pantheon": "dock",
    "sway": "tree",
    "hyprland": "split",
    "hyprland-noctalia": "split-shell-round",
    "hyprland-dms": "split-shell-pill",
    "niri": "scroll",
    "niri-noctalia": "scroll-shell-round",
    "niri-dms": "scroll-shell-pill",
    "i3": "tree",
    "minimal": "terminal",
    "generic": "full",
}

EXTRAS: dict[str, str] = {
    "browser": "window",
    "office": "grid",
    "images": "brush",
    "video": "timeline",
    "media": "seek",
    "downloads": "queue",
    "passwords": "key",
    "containers": "box",
    "virtualmachines": "nested",
    "vpn": "route",
    "cloud": "sync",
    "messaging": "speech",
}

EXTRA_ACCENT: dict[str, str] = {
    "browser": "#2563eb",
    "office": "#475569",
    "images": "#4d7c0f",
    "video": "#0369a1",
    "media": "#4338ca",
    "downloads": "#15803d",
    "passwords": "#c2410c",
    "containers": "#4f46e5",
    "virtualmachines": "#0f766e",
    "vpn": "#7e22ce",
    "cloud": "#047857",
    "messaging": "#a21caf",
}


def fmt(v: float) -> str:
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def plate(accent: str) -> list[str]:
    """The light plate every tile sits on, with a soft accent wash in a corner."""
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">',
        f"  <defs><linearGradient id=\"g\" x2=\"1\" y2=\"1\">"
        f'<stop stop-color="{PLATE_TOP}"/><stop offset="1" stop-color="{PLATE_BOTTOM}"/>'
        f"</linearGradient></defs>",
        f'  <rect width="{W}" height="{H}" rx="{RADIUS}" fill="url(#g)"/>',
        f'  <rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="{RADIUS}" '
        f'fill="none" stroke="{EDGE}"/>',
        f'  <circle cx="{W - 60}" cy="34" r="120" fill="{accent}" opacity="0.10"/>',
    ]


def box(x: float, y: float, w: float, h: float, fill: str,
        rx: float = 8, stroke: str | None = None, opacity: float = 1.0) -> str:
    op = "" if opacity == 1.0 else f' opacity="{fmt(opacity)}"'
    st = "" if stroke is None else f' stroke="{stroke}" stroke-width="1"'
    return (f'  <rect x="{fmt(x)}" y="{fmt(y)}" width="{fmt(w)}" height="{fmt(h)}" '
            f'rx="{fmt(rx)}" fill="{fill}"{st}{op}/>')


def dot(x: float, y: float, r: float, fill: str, opacity: float = 1.0) -> str:
    return (f'  <circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(r)}" '
            f'fill="{fill}" opacity="{fmt(opacity)}"/>')


def window(x: float, y: float, w: float, h: float, accent: str,
           focused: bool = False, lines: int = 3) -> list[str]:
    out = [box(x, y, w, h, CARD, 8, accent if focused else EDGE)]
    out.append(box(x, y, w, 6, accent, 3, None, 0.85 if focused else 0.35))
    for i in range(lines):
        out.append(box(x + 10, y + 18 + i * 22, w - 20 - (i * 8 if i else 0), 9,
                       INK, 4, None, 0.55 - i * 0.12))
    return out


def bar_top(accent: str) -> list[str]:
    out = [box(0, 0, W, 24, BAR, 0)]
    for i in range(3):
        out.append(dot(22 + i * 16, 12, 4, accent, 0.9 if i == 0 else 0.45))
    out.append(box(80, 8, 110, 8, "#ffffff", 4, None, 0.9))
    out.append(box(W - 74, 8, 50, 8, "#ffffff", 4, None, 0.8))
    return out


def bar_bottom(accent: str) -> list[str]:
    out = [box(0, H - 26, W, 26, BAR, 0)]
    for i in range(3):
        out.append(dot(22 + i * 16, H - 13, 4, accent, 0.9 if i == 0 else 0.45))
    out.append(box(80, H - 17, 130, 8, "#ffffff", 4, None, 0.9))
    out.append(box(W - 84, H - 17, 60, 8, "#ffffff", 4, None, 0.8))
    return out


def shell_bar(accent: str, pill: bool) -> list[str]:
    out = [box(0, H - 36, W, 36, BAR, 0)]
    if pill:
        x = 18
        for w in (52, 38, 64, 32):
            out.append(box(x, H - 26, w, 16, CARD, 8, accent))
            x += w + 9
    else:
        out.append(box(18, H - 26, 140, 16, CARD, 8, accent))
        for i in range(3):
            out.append(dot(180 + i * 24, H - 18, 5, accent, 0.8 - i * 0.2))
        out.append(box(W - 88, H - 26, 70, 16, CARD, 8, EDGE))
    return out


def sk_full(accent: str) -> list[str]:
    out = bar_top(accent)
    out += window(22, 42, 130, 156, accent, lines=4)
    out += window(168, 36, 166, 168, accent, focused=True, lines=4)
    out += window(350, 48, 108, 148, accent, lines=3)
    out += bar_bottom(accent)
    return out


def sk_panel(accent: str, top: bool) -> list[str]:
    out = bar_top(accent) if top else bar_bottom(accent)
    ty = 40 if top else 48
    out += window(24, ty, 186, H - ty - 58, accent, lines=5)
    out += window(226, ty + 8, 230, H - ty - 74, accent, focused=True, lines=4)
    return out


def sk_dock(accent: str) -> list[str]:
    out = bar_top(accent)
    out += window(24, 44, 190, 158, accent, lines=4)
    out += window(230, 44, 226, 158, accent, focused=True, lines=4)
    out.append(box(0, H - 42, W, 42, BAR, 0))
    out.append(box(146, H - 34, 188, 28, CARD, 14, accent))
    for i in range(5):
        out.append(dot(170 + i * 36, H - 20, 6, accent, 0.85 if i == 1 else 0.4))
    return out


def sk_scroll(accent: str, heights: list[int]) -> list[str]:
    out = []
    x = 26
    for i, hgt in enumerate(heights):
        top = 196 - hgt
        out += window(x, top, 62, hgt, accent, focused=(i == 2), lines=2)
        x += 70
    return out


def sk_split(accent: str, cols: list[int], gap: int) -> list[str]:
    out = []
    total = W - 48
    widths = [int(total * c / sum(cols)) for c in cols]
    x = 24
    for i, w in enumerate(widths):
        if i:
            x += gap
        out += window(x, 38, w, 184, accent, focused=(i == 0), lines=4)
        x += w
    return out


def sk_tree(accent: str) -> list[str]:
    out = window(24, 38, 238, 184, accent, focused=True, lines=4)
    out += window(278, 38, 178, 114, accent, lines=3)
    out += window(278, 166, 178, 56, accent, lines=1)
    out.append(box(0, H - 26, W, 26, BAR, 0))
    out.append(dot(18, H - 13, 5, accent))
    out.append(box(34, H - 17, 86, 8, "#ffffff", 4))
    out.append(box(W - 90, H - 17, 76, 8, CARD, 4, EDGE))
    return out


def sk_terminal(accent: str) -> list[str]:
    out = window(28, 42, 424, 182, accent, focused=True, lines=0)
    out.append(box(28, 42, 424, 6, accent, 3, None, 0.85))
    for i, w in enumerate((300, 220, 260, 180, 240)):
        out.append(box(44, 76 + i * 26, w, 9, accent if i == 0 else INK,
                       4, None, 0.9 if i == 0 else 0.6))
    out.append(box(44, 200, 14, 14, accent, 3))
    return out


def sk_glyph(accent: str, kind: str) -> list[str]:
    out = []
    cx, cy = W / 2, 134
    if kind == "window":
        out += window(150, 58, 180, 136, accent, focused=True, lines=5)
    elif kind == "grid":
        out.append(box(156, 56, 168, 140, CARD, 8, EDGE))
        for r in range(3):
            for c in range(3):
                out.append(box(170 + c * 46, 72 + r * 38, 32, 26, BAR, 4, EDGE))
        out.append(box(170, 72, 32, 26, accent, 4, None, 0.5))
    elif kind == "brush":
        out.append(box(150, 62, 180, 130, CARD, 8, EDGE))
        for i in range(5):
            out.append(box(166 + i * 32, 88, 12, 66, accent, 6, None, 0.35 + i * 0.1))
        out.append(box(150, 176, 180, 12, BAR, 6, EDGE))
    elif kind == "timeline":
        out.append(box(128, 52, 224, 116, CARD, 8, EDGE))
        out.append(box(142, 66, 196, 12, accent, 4, None, 0.5))
        out.append(box(142, 88, 150, 8, INK, 4))
        out.append(box(142, 104, 176, 8, INK, 4))
        out.append(box(128, 176, 224, 14, BAR, 4, EDGE))
        out.append(box(136, 178, 98, 10, accent, 5))
        for i in range(5):
            out.append(dot(140 + i * 52, 190, 4, INK, 0.8))
    elif kind == "seek":
        out.append(box(136, 54, 208, 128, CARD, 8, EDGE))
        out.append(box(136, 54, 208, 128, accent, 8, None, 0.16))
        out.append(dot(240, 116, 30, CARD, 0.95))
        out.append(dot(240, 116, 22, accent, 0.75))
        out.append(box(152, 116, 176, 4, EDGE, 2))
        out.append(box(152, 160, 176, 4, EDGE, 2))
        out.append(box(152, 160, 92, 4, accent, 2))
        for i in range(4):
            out.append(box(152 + i * 44, 68, 22, 14, BAR, 3, EDGE))
    elif kind == "queue":
        for i, w in enumerate((236, 188, 208, 148)):
            out.append(box(138, 58 + i * 32, w, 22, CARD if i else BAR, 5, EDGE))
            out.append(box(144, 65 + i * 32, 8, 8, accent, 4, None, 0.8))
            out.append(box(158, 66 + i * 32, (w - 34) * 0.6, 6, INK, 3))
        out.append(box(138, 190, 126, 8, accent, 4))
    elif kind == "key":
        out.append(dot(cx - 36, cy, 32, accent, 0.55))
        out.append(box(cx - 6, cy - 7, 84, 14, BAR, 7, EDGE))
        out.append(box(cx + 40, cy + 4, 10, 24, BAR, 4, EDGE))
        out.append(box(cx + 60, cy + 4, 10, 24, BAR, 4, EDGE))
        out.append(dot(cx - 36, cy, 12, CARD))
    elif kind == "box":
        out.append(box(140, 50, 200, 146, CARD, 10, EDGE))
        out.append(box(140, 50, 200, 24, accent, 10, None, 0.65))
        out.append(dot(160, 62, 4, CARD, 0.9))
        out.append(dot(176, 62, 4, CARD, 0.9))
        out.append(box(176, 88, 128, 92, BAR, 8, EDGE))
        out.append(box(190, 100, 100, 9, accent, 4))
        out.append(box(190, 118, 100, 9, INK, 4))
        out.append(box(190, 136, 62, 9, INK, 4))
        out.append(box(190, 156, 44, 7, accent, 3, None, 0.8))
    elif kind == "nested":
        out.append(box(122, 42, 236, 156, CARD, 10, EDGE))
        out.append(box(122, 42, 236, 24, accent, 10, None, 0.65))
        for i in range(3):
            out.append(dot(144 + i * 14, 54, 4, CARD, 0.9))
        out.append(box(150, 82, 180, 100, BAR, 8, EDGE))
        out.append(box(162, 94, 156, 9, accent, 4, None, 0.6))
        for i in range(3):
            out.append(box(162, 114 + i * 20, 156 - i * 34, 9, INK, 4))
    elif kind == "route":
        out.append(box(136, 72, 72, 62, CARD, 8, accent))
        out.append(box(272, 72, 72, 62, CARD, 8, EDGE))
        out.append(dot(172, 103, 6, accent))
        out.append(dot(308, 103, 6, INK))
        out.append(box(210, 100, 60, 5, BAR, 2))
        out.append(box(170, 134, 140, 5, BAR, 2))
        out.append(dot(310, 136, 5, INK))
    elif kind == "sync":
        for i, x in enumerate((164, 238)):
            out.append(box(x, 60, 78, 24, CARD, 12, accent if i == 0 else EDGE))
        out.append(box(164, 118, 78, 24, CARD, 12, EDGE))
        out.append(box(238, 118, 78, 24, CARD, 12, accent))
        out.append(box(196, 92, 88, 5, BAR, 2))
        out.append(box(196, 146, 88, 5, BAR, 2))
        out.append(dot(286, 94, 5, accent))
        out.append(dot(194, 148, 5, INK))
    elif kind == "speech":
        out.append(box(138, 64, 108, 68, CARD, 14, accent))
        out.append(box(234, 92, 108, 68, CARD, 14, EDGE))
        for i in range(2):
            out.append(dot(172, 98, 4, INK))
            out.append(dot(266, 126, 4, INK))
    else:
        out += window(150, 58, 180, 136, accent, lines=4)
    return out


def build_desktop(ident: str) -> str:
    accent = PALETTE[ident]
    kind = SKETCH[ident]
    out = plate(accent)
    if kind == "full":
        out += sk_full(accent)
    elif kind.startswith("panel-"):
        out += sk_panel(accent, kind.endswith("top"))
    elif kind == "dock":
        out += sk_dock(accent)
    elif kind == "scroll":
        out += sk_scroll(accent, [54, 76, 98, 68, 46])
    elif kind == "scroll-shell-round":
        out += shell_bar(accent, False) + sk_scroll(accent, [48, 68, 88, 60, 40])
    elif kind == "scroll-shell-pill":
        out += shell_bar(accent, True) + sk_scroll(accent, [48, 68, 88, 60, 40])
    elif kind == "split":
        out += sk_split(accent, [3, 2, 1], 10)
    elif kind == "split-shell-round":
        out += shell_bar(accent, False) + sk_split(accent, [3, 2], 12)
    elif kind == "split-shell-pill":
        out += shell_bar(accent, True) + sk_split(accent, [3, 2], 12)
    elif kind == "tree":
        out += sk_tree(accent)
    elif kind == "terminal":
        out += sk_terminal(accent)
    else:
        out += sk_full(accent)
    out.append("</svg>")
    return "\n".join(out) + "\n"


def build_extra(ident: str) -> str:
    accent = EXTRA_ACCENT[ident]
    out = plate(accent)
    out += sk_glyph(accent, EXTRAS[ident])
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main() -> int:
    BRANDING.mkdir(parents=True, exist_ok=True)
    n = 0
    for ident in sorted(SKETCH):
        (BRANDING / f"desktop-{ident}.svg").write_text(
            build_desktop(ident), encoding="utf-8", newline="\n")
        n += 1
    for ident in sorted(EXTRAS):
        (BRANDING / f"extras-{ident}.svg").write_text(
            build_extra(ident), encoding="utf-8", newline="\n")
        n += 1
    print(f"  wrote {n} tiles into {BRANDING.relative_to(PROJECT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
