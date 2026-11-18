// tests/js/tiling-layout.test.js: unit tests for tiling/layout.js. Run with tests/js-test.sh.
import {rectFor, zoneAt, nextTile, freeTile, followEdges} from '../../modules/gnome/extensions/tiling/layout.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const mon = {x: 0, y: 0, width: 1920, height: 1080};
const wa = {x: 0, y: 32, width: 1920, height: 1048}; // below a 32 px top bar

check('left half', eq(rectFor('left', wa), {x: 0, y: 32, width: 960, height: 1048}));
check('bottom-right quarter', eq(rectFor('br', wa), {x: 960, y: 556, width: 960, height: 524}));
const l = rectFor('left', wa, 8), r = rectFor('right', wa, 8);
check('gap: full at the screen edge', l.x === 8 && l.y === 40 && r.x + r.width === 1912);
check('gap: one gap between neighbours', r.x - (l.x + l.width) === 8);

check('left edge middle → left half', zoneAt(0, 540, mon, wa) === 'left');
check('left edge top → top-left quarter', zoneAt(0, 100, mon, wa) === 'tl');
check('right edge bottom → bottom-right quarter', zoneAt(1919, 1000, mon, wa) === 'br');
check('top edge middle → maximize', zoneAt(960, 0, mon, wa) === 'max');
check('top edge left end → top-left quarter', zoneAt(100, 0, mon, wa) === 'tl');
check('bottom edge middle → nothing (the dock lives there)', zoneAt(960, 1079, mon, wa) === null);
check('away from the edges → nothing', zoneAt(500, 500, mon, wa) === null);
check('second monitor offset', zoneAt(1920, 540, {x: 1920, y: 0, width: 1920, height: 1080}, {x: 1920, y: 0, width: 1920, height: 1080}) === 'left');

check('untiled + left → left half', nextTile(null, 'left') === 'left');
check('left half + up → top-left quarter', nextTile('left', 'up') === 'tl');
check('top-left + down → left half', nextTile('tl', 'down') === 'left');
check('top-right + left → top-left', nextTile('tr', 'left') === 'tl');
check('right half + left → restore', nextTile('right', 'left') === 'restore');
check('maximized + down → restore', nextTile('max', 'down') === 'restore');
check('untiled + up → maximize', nextTile(null, 'up') === 'max');

check('left tiled → offer right half', freeTile([rectFor('left', wa)], wa) === 'right');
check('left + top-right → offer bottom-right', freeTile([rectFor('left', wa), rectFor('tr', wa)], wa) === 'br');
check('gapped left still leaves right free', freeTile([rectFor('left', wa, 8)], wa) === 'right');
check('full screen → nothing free', freeTile([rectFor('left', wa), rectFor('right', wa)], wa) === null);
check('nothing tiled → left half', freeTile([], wa) === 'left');

const before = rectFor('left', wa), after = {...before, width: 1100};
const moved = followEdges(before, after, [rectFor('right', wa)]);
check('right neighbour follows a widened left half', eq(moved.get(0), {x: 1100, y: 32, width: 820, height: 1048}));
const quads = [rectFor('tr', wa), rectFor('br', wa), rectFor('bl', wa)];
const tl = rectFor('tl', wa), tlTaller = {...tl, height: 600};
const m2 = followEdges(tl, tlTaller, quads);
check('quarter grown down: bottom-left shrinks, right column untouched',
    eq(m2.get(2), {x: 0, y: 632, width: 960, height: 448}) && !m2.has(0) && !m2.has(1));
const rr = rectFor('right', wa), rrWider = {...rr, x: 800, width: 1120};
check('left neighbour follows a right half widened leftwards',
    eq(followEdges(rr, rrWider, [rectFor('left', wa)]).get(0), {x: 0, y: 32, width: 800, height: 1048}));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
