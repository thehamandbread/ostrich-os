// tests/js/alert-place.test.js: unit tests for _lib/place.js. Run with tests/js-test.sh.
import {placeUnder} from '../../modules/gnome/extensions/_lib/place.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const monitor = {x: 0, width: 1920};
const at = (x, w) => placeUnder({x, y: 0, width: w, height: 32}, monitor, 32, 360);

check('centred under its source', at(800, 120).x === 680 && at(800, 120).y === 40);
check('kept off the left edge', at(10, 60).x === 8);
check('kept off the right edge', at(1880, 40).x === 1920 - 360 - 8);
check('on a second monitor, inside it', placeUnder({x: 1930, y: 0, width: 50, height: 32}, {x: 1920, width: 1280}, 32, 360).x === 1928);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
