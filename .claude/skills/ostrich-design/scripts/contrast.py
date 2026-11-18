#!/usr/bin/env python3
# contrast.py FG BG [UNDER]: the WCAG 2.x contrast ratio of two colours (references/accessibility.md).
# Colours: #rgb, #rrggbb, rgb(r,g,b) or rgba(r,g,b,a). A translucent FG or BG is laid over the next
# colour (FG over BG; BG over UNDER, default black, as glass over a dark desktop).
# Prints the ratio and whether it passes 4.5:1 (text), 3:1 (large text, icons, borders).
import re
import sys


def parse(s):
    s = s.strip()
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4)) + (1.0,)
    m = re.fullmatch(r"rgba?\(([^)]*)\)", s)
    if not m:
        sys.exit(f"not a colour: {s}")
    p = [float(x) for x in m.group(1).split(",")]
    return (p[0], p[1], p[2], p[3] if len(p) > 3 else 1.0)


def over(top, under):
    a = top[3]
    return tuple(top[i] * a + under[i] * (1 - a) for i in range(3)) + (1.0,)


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def ratio(fg, bg, under=(0, 0, 0, 1.0)):
    bg = over(bg, under)
    fg = over(fg, bg)
    a, b = sorted((lum(fg), lum(bg)), reverse=True)
    return (a + 0.05) / (b + 0.05)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: contrast.py FG BG [UNDER]")
    under = parse(sys.argv[3]) if len(sys.argv) == 4 else (0, 0, 0, 1.0)
    r = ratio(parse(sys.argv[1]), parse(sys.argv[2]), under)
    verdict = "text OK" if r >= 4.5 else "large text/icons only" if r >= 3 else "FAILS"
    print(f"{r:.2f}:1  {verdict}")
