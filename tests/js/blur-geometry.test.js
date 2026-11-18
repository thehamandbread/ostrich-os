// tests/js/blur-geometry.test.js: unit tests for blur/geometry.js. Run with tests/js-test.sh.
import {overlaps, paddedRect} from '../../modules/gnome/extensions/blur/geometry.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const stage = {width: 1920, height: 1080};
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

check('the top bar grows down only (the screen edge above)',
    eq(paddedRect({x: 0, y: 0, width: 1920, height: 32}, 60, stage), {x: 0, y: 0, width: 1920, height: 92}));
check('a menu grows on every side',
    eq(paddedRect({x: 1500, y: 40, width: 300, height: 400}, 60, stage), {x: 1440, y: 0, width: 420, height: 500}));
check('the dock is kept on the stage at the bottom',
    eq(paddedRect({x: 800, y: 1020, width: 320, height: 52}, 60, stage), {x: 740, y: 960, width: 440, height: 120}));
check('no margin: the surface itself', eq(paddedRect({x: 5, y: 6, width: 7, height: 8}, 0, stage), {x: 5, y: 6, width: 7, height: 8}));
check('a window far below the top bar is not under it',
    !overlaps({x: 460, y: 150, width: 1000, height: 700}, {x: 0, y: 0, width: 1920, height: 44}));
check('a window touching the area\'s edge is not under it',
    !overlaps({x: 0, y: 44, width: 500, height: 500}, {x: 0, y: 0, width: 1920, height: 44}));
check('a maximized window is under the top bar',
    overlaps({x: 0, y: 32, width: 1920, height: 1048}, {x: 0, y: 0, width: 1920, height: 44}));
check('off the stage: empty', paddedRect({x: 3000, y: 0, width: 10, height: 10}, 5, stage).width === 0);

check('the top bar with a small margin below',
    eq(paddedRect({x: 0, y: 0, width: 1920, height: 32}, 60, stage, {below: 12}), {x: 0, y: 0, width: 1920, height: 44}));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
