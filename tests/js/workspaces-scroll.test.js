// tests/js/workspaces-scroll.test.js: unit tests for workspaces/scroll.js. Run with tests/js-test.sh.
import {QUIET_MS, ScrollGate} from '../../modules/gnome/extensions/workspaces/scroll.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

// A touchpad swipe: 60 events, 8 ms apart, 0.3 each (18 units, ~480 ms, longer than GNOME's 150 ms).
let g = new ScrollGate();
let moved = 0;
for (let i = 0; i < 60; i++)
    moved += g.step(1000 + i * 8, 0.3);
check('one long touchpad swipe moves one workspace', moved === 1);

// The next swipe after a quiet pause moves one more.
let t = 1000 + 60 * 8 + QUIET_MS;
for (let i = 0; i < 20; i++)
    moved += g.step(t + i * 8, 0.3);
check('a second swipe after a pause moves one more', moved === 2);

// A fast flick of the wheel: 5 clicks 30 ms apart.
g = new ScrollGate();
moved = 0;
for (let i = 0; i < 5; i++)
    moved += g.step(i * 30, 1);
check('a fast flick of 5 wheel clicks moves one workspace', moved === 1);

// Slow, separate wheel clicks each move one.
g = new ScrollGate();
moved = 0;
for (let i = 0; i < 3; i++)
    moved += g.step(i * (QUIET_MS + 50), -1);
check('three separate wheel clicks move three, backwards', moved === -3);

// A tiny touchpad nudge doesn't move.
g = new ScrollGate();
check('a nudge under one unit does nothing', g.step(0, 0.4) === 0 && g.step(10, 0.4) === 0);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
