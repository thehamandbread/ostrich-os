// tests/js/drawer-bar.test.js: unit tests for drawer/barlogic.js. Run with tests/js-test.sh.
import {badgeText, splitBar, siteSize, placeUnder, inside, hoverStep, hoverDelay, NARROW_WIDTH, HOVER_CLOSE_MS} from '../../modules/gnome/extensions/drawer/barlogic.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

check('badges', badgeText(0) === '' && badgeText(3) === '3' && badgeText(12) === '9+' && badgeText(NaN) === '');

const bar = ['messages', 'chat', 'claude', 'youtube', 'gmail'];
check('first four shown, the rest in the menu', JSON.stringify(splitBar(bar, 4)) === JSON.stringify({shown: bar.slice(0, 4), overflow: ['gmail']}));
check('zero icons: all in the menu', splitBar(bar, 0).shown.length === 0 && splitBar(bar, 0).overflow.length === 5);

const area = {width: 1920, height: 1048};
const wide = {width: 50, height: 60};
const w = siteSize({shape: 'wide', width: 0, height: 0}, area, wide);
check('wide: percent of the area', w.width === 960 && w.height === 629);
const n = siteSize({shape: 'narrow', width: 0, height: 0}, area, wide);
check('narrow: phone width, 75 % tall', n.width === NARROW_WIDTH && n.height === 786);
check('a resized site keeps its size', JSON.stringify(siteSize({shape: 'wide', width: 700, height: 500}, area, wide)) === '{"width":700,"height":500}');
check('sizes stay on the screen and usable', JSON.stringify(siteSize({shape: 'wide', width: 9000, height: 10}, area, wide)) === '{"width":1920,"height":240}');

const m = {x: 0, width: 1920};
check('centred under the icon', placeUnder(1000, 400, m, 8) === 800);
check('kept inside on the right', placeUnder(1900, 400, m, 8) === 1512);
check('kept inside on the left', placeUnder(10, 400, m, 8) === 8);
check('full width: no gap', placeUnder(500, 1920, m, 8) === 0);
check('second monitor', placeUnder(2000, 400, {x: 1920, width: 1920}, 8) === 1928);

check('inside a rect', inside({x: 0, y: 0, width: 10, height: 10}, 5, 5) && !inside({x: 0, y: 0, width: 10, height: 10}, 10, 5) && !inside(null, 0, 0));

let s = hoverStep({outsideSince: null, engaged: false, now: 1000, pointerInside: false});
check('leaving starts the countdown', s.outsideSince === 1000 && !s.close);
s = hoverStep({outsideSince: s.outsideSince, engaged: false, now: 1000 + HOVER_CLOSE_MS - 1, pointerInside: false});
check('not closed before the delay', !s.close);
s = hoverStep({outsideSince: s.outsideSince, engaged: false, now: 1000 + HOVER_CLOSE_MS, pointerInside: false});
check('closed after the delay', s.close);
check('coming back resets it', hoverStep({outsideSince: 1000, engaged: false, now: 5000, pointerInside: true}).outsideSince === null);
check('engaged never closes', !hoverStep({outsideSince: 0, engaged: true, now: 99999, pointerInside: false}).close);

const hd = o => hoverDelay({shown: false, active: 'a', id: 'b', delay: 500, switchDelay: 250, ...o});
check('closed: a real pause', hd({}) === 500);
check('open on another site: the switch delay', hd({shown: true}) === 250);
check('open on this site: nothing', hd({shown: true, id: 'a'}) === null);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
