// tests/js/bt-pick.test.js: unit tests for tweaks/btpick.js. Run with tests/js-test.sh.
import {pickRecent} from '../../modules/gnome/extensions/tweaks/btpick.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const dev = (alias, over = {}) => ({alias, address: alias, paired: true, connected: false, ...over});
const names = l => l.map(d => d.alias).join(',');

check('connected first', names(pickRecent([dev('a'), dev('b', {connected: true})], [])) === 'b,a');
check('then the most recent', names(pickRecent([dev('a'), dev('b'), dev('c')], ['c', 'a'])) === 'c,a,b');
check('then by name', names(pickRecent([dev('z'), dev('m')], [])) === 'm,z');
check('unpaired never', names(pickRecent([dev('a', {paired: false}), dev('b')], [])) === 'b');
check('at most three', pickRecent([dev('a'), dev('b'), dev('c'), dev('d')], []).length === 3);
check('none paired, none shown', pickRecent([dev('a', {paired: false})], []).length === 0);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
