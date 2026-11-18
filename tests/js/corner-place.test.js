// tests/js/corner-place.test.js: unit tests for tweaks/cornerplace.js. Run with tests/js-test.sh.
import {cornerFor} from '../../modules/gnome/extensions/tweaks/cornerplace.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const mon = (x, y, width, height = 1080) => ({x, y, width, height});
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const one = mon(0, 0, 1920);
check('one monitor: its top-right corner', eq(cornerFor([one], one), {x: 1920, y: 0}));
const left = mon(0, 0, 1920), right = mon(1920, 0, 1280);
check('primary left of another: corner at the outer edge', eq(cornerFor([left, right], left), {x: 3200, y: 0}));
check('primary on the right: its own edge', eq(cornerFor([left, right], right), {x: 3200, y: 0}));
check('a lower monitor to the right does not move it', eq(cornerFor([left, mon(1920, 400, 1280)], left), {x: 1920, y: 0}));
check('a taller monitor covering the corner: none', cornerFor([left, mon(1920, -200, 1280, 1400)], left) === null);
check('no primary: none', cornerFor([left], null) === null);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
