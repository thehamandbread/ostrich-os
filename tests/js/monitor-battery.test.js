// tests/js/monitor-battery.test.js: unit tests for monitor/battery.js. Run with tests/js-test.sh.
import {lowBatteryRule, saverValue, SAVER_DESKTOP} from '../../modules/gnome/extensions/monitor/battery.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const base = {onBattery: true, percent: 50, profile: 'balanced', threshold: 20, autoFrom: ''};

check('above the threshold: nothing', lowBatteryRule(base) === null);
check('at 20 % on battery: power saver, remembering balanced',
    eq(lowBatteryRule({...base, percent: 20}), {switchTo: 'power-saver', autoFrom: 'balanced'}));
check('performance on battery is left alone until the threshold',
    lowBatteryRule({...base, profile: 'performance', percent: 60}) === null);
check('already in power saver: nothing',
    lowBatteryRule({...base, percent: 10, profile: 'power-saver'}) === null);
check('rule off (0): nothing even at 5 %', lowBatteryRule({...base, percent: 5, threshold: 0}) === null);
check('switched once: no repeat while still low',
    lowBatteryRule({...base, percent: 15, profile: 'balanced', autoFrom: 'performance'}) === null);
check('plugged in after the switch: back to the previous mode',
    eq(lowBatteryRule({...base, onBattery: false, percent: 15, profile: 'power-saver', autoFrom: 'performance'}),
        {switchTo: 'performance', autoFrom: ''}));
check('plugged in, but the user picked a mode since: theirs stays',
    eq(lowBatteryRule({...base, onBattery: false, profile: 'balanced', autoFrom: 'performance'}),
        {switchTo: null, autoFrom: ''}));
check('plugged in, rule never fired: nothing', lowBatteryRule({...base, onBattery: false}) === null);

check('idle delay shortens to 2 min', saverValue('idle-delay', 120, 300) === 120);
check('a shorter idle delay of the user stays', saverValue('idle-delay', 120, 60) === 60);
check('idle delay 0 (never, the user\'s choice) stays in saver', saverValue('idle-delay', 120, 0) === 0);
check('animations stay on in saver', !SAVER_DESKTOP.some(([, key]) => key === 'enable-animations'));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
