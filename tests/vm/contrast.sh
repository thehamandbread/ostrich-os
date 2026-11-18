#!/usr/bin/env bash
# tests/vm/contrast.sh: text contrast in a screenshot, approximately as WCAG measures it. Each line
# of text in a box is found (rows with ink), and its contrast is taken between the 3rd and 97th
# luminance percentiles (glyph core vs background; anti-aliasing makes this a slight underestimate).
# Fails when a line is under the floor (4.5:1, body text). The council's test T5 used this method.
#
#   contrast.sh [--min RATIO] [--peak] IMAGE X0,Y0,X1,Y1[:LABEL]...
#
# --peak takes the 0.2nd and 99.8th percentiles instead: the glyph's brightest core against the
# background. Small thin labels (quick-settings tiles, 11 px) never reach their colour at the 97th
# percentile, so the default read white on a 4.95:1 fill as 4.2:1 (council 2026-11-09; sampled by
# hand: the cores were the text colour). Use it only on boxes that hold text and its fill alone.
#
# Give boxes around text only (a label column, not icons or lit buttons beside it). Writes a line
# per text line found: ratio, PASS/FAIL, label, and its y range.
set -euo pipefail
MIN=4.5
LO=0.03
while (($# > 0)); do
	case $1 in
	--min) MIN=$2 && shift 2 ;;
	--peak) LO=0.002 && shift ;;
	*) break ;;
	esac
done
(($# >= 2)) || {
	echo "usage: contrast.sh [--min RATIO] [--peak] IMAGE X0,Y0,X1,Y1[:LABEL]..." >&2
	exit 2
}
python3 -I - "$MIN" "$LO" "$@" <<'EOF'
import sys
from PIL import Image

floor, lo_q, path, boxes = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4:]
img = Image.open(path).convert("RGB")

def lum(rgb):
    def ch(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)

def ratio(values):
    v = sorted(values)
    lo, hi = v[int(len(v) * lo_q)], v[min(len(v) - 1, int(len(v) * (1 - lo_q)))]
    return (hi + 0.05) / (lo + 0.05)

failed = 0
for spec in boxes:
    coords, _, label = spec.partition(":")
    x0, y0, x1, y1 = (int(n) for n in coords.split(","))
    rows = [[lum(img.getpixel((x, y))) for x in range(x0, x1)] for y in range(y0, y1)]
    # A row has ink when it isn't flat: its spread is well above the background's.
    inked = [max(r) - min(r) > 0.04 for r in rows]
    lines, start = [], None
    for i, on in enumerate(inked + [False]):
        if on and start is None:
            start = i
        elif not on and start is not None:
            if i - start >= 6:  # shorter is a rule or a speck, not text
                lines.append((start, i))
            start = None
    if not lines:
        print(f"  none   ----  {label or coords}: no text found")
        failed += 1
        continue
    for a, b in lines:
        # A margin of background above and below, so the percentiles see both.
        pad = 3
        vals = [v for r in rows[max(0, a - pad):min(len(rows), b + pad)] for v in r]
        r = ratio(vals)
        ok = r >= floor
        failed += not ok
        print(f"{r:6.2f}:1  {'PASS' if ok else 'FAIL'}  {label or coords} (y {y0 + a}-{y0 + b})")
print(f"# {'all lines pass' if not failed else f'{failed} under {floor}:1'}")
sys.exit(1 if failed else 0)
EOF
