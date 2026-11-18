// tests/js/monitor-memory.test.js: unit tests for monitor/memory.js. Run with tests/js-test.sh.
import {memoryPressure, memoryWarningRule, biggestApp, warningText, blames} from '../../modules/gnome/extensions/monitor/memory.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

const gb = n => n * 1048576;
// 32 GB, 8 GB swap; 30 GB in use plus a full swap: the owner's Dell after two days.
const full = {totalKb: gb(32), availableKb: gb(2), swapTotalKb: gb(8), swapUsedKb: gb(8)};
check('memory and swap count together', Math.round(memoryPressure(full)) === 95);
check('no reading: no pressure', memoryPressure(null) === null);
check('no swap is fine', Math.round(memoryPressure({totalKb: 100, availableKb: 50})) === 50);

let s = memoryWarningRule(95, false);
check('warns when it passes 85 %', s.warn && s.warned);
s = memoryWarningRule(90, s.warned);
check('once: not again while it stays high', !s.warn && s.warned);
s = memoryWarningRule(80, s.warned);
check('not again between 75 and 85 %', !s.warn && s.warned);
s = memoryWarningRule(70, s.warned);
check('cleared below 75 %', !s.warn && !s.warned);
check('warns again after clearing', memoryWarningRule(86, s.warned).warn);
check('no reading: no warning', !memoryWarningRule(null, false).warn);

const big = biggestApp([['Firefox', gb(3)], ['Files', gb(1)], ['Firefox', gb(2)]]);
check('an app\'s processes add up', big.name === 'Firefox' && big.kb === gb(5));
check('nothing running: none', biggestApp([]) === null);
const scoped = biggestApp([['Firefox', gb(3), 'app-firefox-1.scope'], ['Firefox', gb(2), 'app-firefox-1.scope'], ['Firefox', gb(1), 'app-firefox-2.scope']]);
check('its scopes, once each, for End app', JSON.stringify(scoped.scopes) === '["app-firefox-1.scope","app-firefox-2.scope"]');
check('End app is offered only for an app that is blamed', blames(scoped, gb(32)) && !blames({name: 'x', kb: gb(1)}, gb(32)) && !blames(null, gb(32)));
check('names the app and its size', warningText(big, gb(32)).startsWith('Firefox is using about 5.0 GB.'));
check('a small app isn\'t blamed', warningText({name: 'Drawer', kb: gb(0.1)}, gb(6)).startsWith('Closing tabs'));
check('without an app it still says what to do', warningText(null, gb(32)).startsWith('Closing tabs'));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
