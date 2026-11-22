#!/usr/bin/env python3
# spec-sheet.py [OUT.html]: the Ostrich design spec on one page (speeds, curves, corners, space,
# targets, density, wording, glass), built from the files that set them, so it can't go stale:
#   tools/icons/tokens.toml (sizes), tools/icons/palette.toml (colours),
#   modules/gnome/extensions/_lib/motion.js (durations).
# The rules quoted come from the skill's references/ (each with its source there).
# Writes OUT.html (default: ostrich-design-spec.html in the current folder). Standard library only.
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]


def pairs(path):
    out = {}
    for line in (ROOT / path).read_text().splitlines():
        m = re.match(r'^([a-z_]+)\s*=\s*"([^"]*)"\s*(?:#\s*(.*))?$', line)
        if m:
            out[m.group(1)] = (m.group(2), m.group(3) or "")
    return out


def px(v):
    """'12px' -> 12; anything else (em) -> 0."""
    return int(v[:-2]) if v.endswith("px") and v[:-2].isdigit() else 0


def motion():
    src = (ROOT / "modules/gnome/extensions/_lib/motion.js").read_text()
    consts = {m.group(1): (int(m.group(2)), m.group(3) or "")
              for m in re.finditer(r"export const (\w+) = (\d+);(?:\s*//\s*(.*))?", src)}
    pop_from = re.search(r"const POP_FROM = ([\d.]+)", src)
    return consts, float(pop_from.group(1)) if pop_from else None


def curve_svg(p1, p2, overshoot):
    # A cubic bezier (0,0)-(1,1) sampled, with the "done" line, to scale.
    w, h, x0, y0 = 220, 110, 30, 135
    def b(a, c, t):
        u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * c + t ** 3
    pts = " ".join(f"{x0 + b(p1[0], p2[0], t / 60) * w:.1f},{y0 - b(p1[1], p2[1], t / 60) * h:.1f}" for t in range(61))
    top = y0 - h
    return (f'<svg viewBox="0 0 270 160" role="img" aria-label="speed curve">'
            f'<line x1="{x0}" y1="{y0}" x2="{x0 + w}" y2="{y0}" class="axis"/>'
            f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{top - 15}" class="axis"/>'
            f'<line x1="{x0}" y1="{top}" x2="{x0 + w}" y2="{top}" class="done"/>'
            f'<polyline points="{pts}" class="curve"/>'
            f'<text x="{x0}" y="{y0 + 16}">start</text><text x="{x0 + w - 30}" y="{y0 + 16}">end</text>'
            f'<text x="0" y="{top + 4}">done</text>'
            + (f'<text x="{x0 + w - 70}" y="{top - 4}">overshoot</text>' if overshoot else "")
            + "</svg>")


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ostrich-design-spec.html")
    t = pairs("tools/icons/tokens.toml")
    pal = pairs("tools/icons/palette.toml")
    m, pop_from = motion()
    e = html.escape

    def row(name, value, note):
        return f"<tr><th scope='row'><code>{e(name)}</code></th><td class='v'>{e(value)}</td><td>{e(note)}</td></tr>"

    radii = "".join(
        f"<figure><div class='swatch' style='border-radius:{min(px(v), 40)}px'></div>"
        f"<figcaption><b>{e(v)}</b><br>{e(k.removeprefix('radius_'))}<br><small>{e(n)}</small></figcaption></figure>"
        for k, (v, n) in t.items() if k.startswith("radius_"))
    spaces = "".join(
        f"<div class='space'><span class='bar' style='width:{px(v) * 4}px'></span>"
        f"<b>{e(v)}</b> <code>{e(k)}</code> <small>{e(n)}</small></div>"
        for k, (v, n) in t.items() if k.startswith("space_") and v.endswith("px"))
    targets = "".join(row(k, v, n) for k, (v, n) in t.items() if k.startswith(("target_", "icon_")))
    speeds = "".join(row(k, f"{v} ms", n) for k, (v, n) in m.items())
    accent = pal.get("accent", ("#f2a541", ""))[0]

    page = f"""<title>Ostrich Design Spec</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
/* One reading column; each section a table or a strip of samples, values in a mono face. */
:root {{ --bg:#f5f6f8; --panel:#ffffff; --fg:#1f2430; --muted:#5b6475; --line:#dde1e8; --accent:{accent};
  --accent-ink:#9a5d08; --ui:"Cantarell","Ubuntu",system-ui,sans-serif; --mono:"JetBrains Mono",ui-monospace,monospace; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#15181f; --panel:#1f2430; --fg:#eef1f6;
  --muted:#a3abbb; --line:#323a4a; --accent-ink:{accent}; color-scheme:dark; }} }}
:root[data-theme="dark"] {{ --bg:#15181f; --panel:#1f2430; --fg:#eef1f6; --muted:#a3abbb; --line:#323a4a;
  --accent-ink:{accent}; color-scheme:dark; }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.55 var(--ui); }}
.wrap {{ max-width:980px; margin:0 auto; padding-block:28px 64px;
  padding-left:max(16px, env(safe-area-inset-left, 0px)); padding-right:max(16px, env(safe-area-inset-right, 0px)); }}
h1 {{ font-size:1.8rem; margin:0 0 4px; text-wrap:balance; }}
h2 {{ font-size:1.15rem; margin:34px 0 10px; padding-top:8px; border-top:2px solid var(--accent); }}
.lede, small, .note {{ color:var(--muted); }} .lede {{ max-width:70ch; }}
code, .v {{ font-family:var(--mono); font-size:.86em; }}
.panel {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px 16px; overflow-x:auto; }}
table {{ border-collapse:collapse; width:100%; min-width:520px; }}
th, td {{ text-align:left; vertical-align:top; padding:7px 10px; border-bottom:1px solid var(--line); }}
tr:last-child > * {{ border-bottom:0; }} th {{ font-weight:600; white-space:nowrap; }}
.grid {{ display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:16px; }}
@media (max-width:720px) {{ .grid {{ grid-template-columns:minmax(0,1fr); }} }}
.swatches {{ display:flex; flex-wrap:wrap; gap:18px; }}
figure {{ margin:0; width:120px; }} figcaption {{ font-size:.85rem; margin-top:6px; }}
.swatch {{ width:96px; height:64px; background:var(--accent); opacity:.9; }}
.space {{ display:flex; align-items:center; gap:10px; margin:6px 0; flex-wrap:wrap; }}
.bar {{ display:inline-block; height:14px; background:var(--accent); border-radius:3px; }}
ul {{ margin:6px 0; padding-left:20px; }} li {{ margin:4px 0; max-width:75ch; }}
svg {{ width:100%; max-width:340px; }} svg text {{ fill:var(--muted); font:11px var(--mono); }}
.axis {{ stroke:var(--line); }} .done {{ stroke:var(--muted); stroke-dasharray:4 4; }}
.curve {{ fill:none; stroke:var(--accent-ink); stroke-width:3; }}
</style>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400&display=swap">
<div class="wrap">
<h1>Ostrich Design Spec</h1>
<p class="lede">How fast things move, how round corners are, how full a menu may get, and the rest of Ostrich OS's design rules on one page. The numbers come straight from the files that set them (<code>tools/icons/tokens.toml</code>, <code>palette.toml</code>, <code>_lib/motion.js</code>); the rules from the <code>ostrich-design</code> skill, where each has its source (GNOME HIG, libadwaita 1.9, GNOME Shell 50's theme, WCAG 2.2, Material 3).</p>

<h2>Motion</h2>
<div class="grid">
<div class="panel"><b>Coming out: Spring</b><p class="note">Grows out of a small copy ({e(f"{pop_from:.0%}" if pop_from else "?")}) at the middle of where it belongs, goes a little past full size, settles. Clutter <code>EASE_OUT_BACK</code> ≈ cubic-bezier(0.34, 1.56, 0.64, 1).</p>{curve_svg((0.34, 1.56), (0.64, 1), True)}</div>
<div class="panel"><b>Going back</b><p class="note">Speeds up into its source. Clutter <code>EASE_IN_QUAD</code> ≈ cubic-bezier(0.55, 0.085, 0.68, 0.53).</p>{curve_svg((0.55, 0.085), (0.68, 0.53), False)}</div>
</div>
<div class="panel" style="margin-top:16px"><table><thead><tr><th>Name</th><th>Duration</th><th>Used for</th></tr></thead><tbody>{speeds}</tbody></table></div>
<ul>
<li>Only position, scale and opacity move; while moving, the surface is one picture on the GPU (nothing redrawn, no blur update).</li>
<li>Things come from where they belong: alerts from their top-bar item, the now-playing pill from the clock, previews from their dock icon.</li>
<li>Reduced Motion (Accessibility) turns every move into a {m.get("QUICK", (120, ""))[0]} ms fade; "Animations" off means no motion at all. Power saver keeps motion.</li>
</ul>

<h2>Corners</h2>
<div class="panel"><div class="swatches">{radii}</div></div>
<ul><li>Match the family: 12 px items inside a 20 px menu; 16 px cards; pills for toggles, the OSD and the now-playing pill. (GNOME Shell 50's own theme.)</li></ul>

<h2>Space</h2>
<div class="panel">{spaces}</div>
<ul><li>Spacing comes in these steps only. Rows and groups sit {e(t.get("space_m", ("12px", ""))[0])} apart; things inside a row {e(t.get("space_s", ("6px", ""))[0])}.</li></ul>

<h2>Targets and sizes that follow the text</h2>
<div class="panel"><table><tbody>{targets}</tbody></table></div>
<ul><li>Nothing to click is smaller than {e(t.get("target_min", ("24px", ""))[0])} (WCAG 2.2, 2.5.8). In the shell, icons and targets are in em so they grow with large text.</li></ul>

<h2>How full a surface may get</h2>
<div class="panel"><table><tbody>
<tr><th>Menu</th><td>3 to 12 items; a submenu 3 to 6; never nest submenus. Group similar items; don't mix actions, checkboxes and radio items in one group.</td></tr>
<tr><th>Popover</th><td>Small: about a third of its window at most. Points at what opened it; Esc closes; no Close button.</td></tr>
<tr><th>Notification / alert</th><td>Up to 3 actions. Ostrich alerts: a title, one plain line, the app's icon.</td></tr>
<tr><th>A page</th><td>One accent action, the thing the page is for. Destructive actions ask once, with a short question.</td></tr>
<tr><th>The top bar</th><td>Readings keep their place: a paused value shows a dash in the same width.</td></tr>
<tr><th>Help text</th><td>One line under a control, never a paragraph in a menu (it stretches the whole menu).</td></tr>
</tbody></table></div>

<h2>Words</h2>
<ul>
<li>Plain and short. Sentence case for descriptions; header case for buttons, menu items, switch labels and tooltips ("Find and Replace").</li>
<li>Tooltips are noun phrases ("Grid View"), not instructions, and never repeat a visible label.</li>
<li>Proper characters: “quotes”, …, × in dimensions, – for ranges, a thin space between number and unit (32 GB).</li>
<li>Never show a raw error. Say what happened and what to do; hide a choice the machine can't do instead of letting it fail.</li>
</ul>

<h2>Glass and power saver</h2>
<ul>
<li>The top bar always blurs the wallpaper only (steady). The dock, menus and banners blur what's behind them, with a light tint and a thin light edge, never a shadow.</li>
<li>Power saver: menus, folders and the overview go solid black; the bar and dock keep their wallpaper blur.</li>
<li>Colours always come from the palette (and the user's colour scheme), never written into a stylesheet.</li>
</ul>

<h2>Before anything is done</h2>
<ul>
<li>Text contrast 4.5:1 (icons, borders, large text 3:1), in light, dark and High contrast.</li>
<li>Everything works with the keyboard, with a visible focus ring; Esc closes.</li>
<li>Every icon-only control has a name a screen reader says.</li>
<li>Looked at in the GPU review VM in light and dark and at 200 % text; no warnings from our code in the shell's log.</li>
</ul>
</div>
"""
    out.write_text(page)
    print(out)


if __name__ == "__main__":
    main()
