// tests/js/tweaks-today.test.js: the Today card's text (tweaks/today.js). Run with tests/js-test.sh.
// today.js imports GNOME Shell's main.js, which plain gjs can't load, so the pure helpers are
// loaded from its source text.
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
const src = new TextDecoder().decode(GLib.file_get_contents(`${here}/../../modules/gnome/extensions/tweaks/today.js`)[1]);
const pick = (start, end) => src.slice(src.indexOf(start), src.indexOf(end));
// eslint-disable-next-line no-new-func
const {duration, batteryLine, cardText} = new Function(`
    const UPOWER_CHARGING = 1, UPOWER_DISCHARGING = 2, UPOWER_FULL = 4;
    const PROFILES = {'performance': 'Performance', 'balanced': 'Balanced', 'power-saver': 'Power Saver'};
    ${pick('export function duration', '// The NVIDIA card').replace(/export /g, '')}
    return {duration, batteryLine, cardText};`)();

check('duration', duration(45 * 60) === '45 min' && duration(3 * 3600) === '3 h' && duration(3 * 3600 + 720) === '3 h 12 min' && duration(90000) === '1 d 1 h');
check('no battery, no line', batteryLine({present: false}) === null);
check('discharging with time left', batteryLine({present: true, percent: 79.6, state: 2, toEmpty: 3 * 3600 + 720}) === 'Battery 80% · 3 h 12 min left');
check('discharging, time unknown', batteryLine({present: true, percent: 50, state: 2, toEmpty: 0}) === 'Battery 50% · estimating');
check('charging', batteryLine({present: true, percent: 50, state: 1, toFull: 2400}) === 'Charging 50% · full in 40 min');
check('full', batteryLine({present: true, percent: 100, state: 4}) === 'Battery full · plugged in');
check('plugged in, not charging', batteryLine({present: true, percent: 80, state: 5}) === 'Battery 80% · plugged in');

const laptop = cardText({battery: 'Battery 54% · 3 h left', profile: 'balanced', nvidia: 'asleep', uptime: 7200});
check('laptop: battery leads, then mode, GPU, uptime', laptop.lead === 'Battery 54% · 3 h left' &&
    laptop.rows.join('|') === 'Power mode: Balanced|NVIDIA GPU asleep|Running for 2 h');
const desktop = cardText({battery: null, profile: 'performance', nvidia: null, uptime: 60});
check('no battery: the power mode leads, no GPU row', desktop.lead === 'Power mode: Performance' && desktop.rows.join('|') === 'Running for 1 min');
check('NVIDIA on', cardText({battery: null, profile: null, nvidia: 'on', uptime: NaN}).lead === 'NVIDIA GPU on');
check('nothing known', cardText({battery: null, profile: null, nvidia: null, uptime: NaN}).lead === null);
check('no "using no power" claim', !src.includes('using no power'));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
