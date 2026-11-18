// tests/js/timers.test.js: _lib/timers.js picks the right GLib clock for an interval. Run with
// tests/js-test.sh. timers.js imports GNOME Shell's main.js, which plain gjs can't load, so the
// helper is loaded from its source text.
import GLib from 'gi://GLib';

let failures = 0;
function check(name, cond) {
    if (cond) {
        print(`ok - ${name}`);
    } else {
        failures++;
        print(`not ok - ${name}`);
    }
}

const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
const src = new TextDecoder().decode(GLib.file_get_contents(`${here}/../../modules/gnome/extensions/_lib/timers.js`)[1]);
const pick = (start, end) => src.slice(src.indexOf(start), src.indexOf(end));
const calls = [];
const FakeGLib = {
    PRIORITY_LOW: 300, PRIORITY_DEFAULT: 0,
    timeout_add_seconds: (priority, s) => calls.push(['seconds', priority, s]),
    timeout_add: (priority, ms) => calls.push(['ms', priority, ms]),
};
// eslint-disable-next-line no-new-func
const addTimeout = new Function('GLib', `${pick('function addTimeout', 'export class')} return addTimeout;`)(FakeGLib);

addTimeout(2, () => {});
addTimeout(0.4, () => {});
check('whole seconds: the seconds clock, low priority', calls[0].join() === 'seconds,300,2');
check('a fraction: milliseconds, default priority', calls[1].join() === 'ms,0,400');

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
