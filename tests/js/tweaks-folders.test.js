// tests/js/tweaks-folders.test.js: unit tests for tweaks/folders.js. Run with tests/js-test.sh.
import {folderTheme} from '../../modules/gnome/extensions/tweaks/folders.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
const base = {current: 'Yaru', choice: 'accent', accent: 'blue', dark: false, scheme: null};
const t = s => folderTheme({...base, ...s});

check('follows the accent', t({}) === 'Yaru-blue');
check('dark style: the -dark variant', t({dark: true, current: 'Yaru-dark'}) === 'Yaru-blue-dark');
check('orange is Yaru itself', t({accent: 'orange', current: 'Yaru-blue'}) === 'Yaru');
check('a colour picked wins over the accent', t({choice: 'sage'}) === 'Yaru-sage');
check('a picked colour stays with a scheme on', t({choice: 'red', scheme: 'forest'}) === 'Yaru-red');
check('following the accent leaves a scheme\'s folders', t({scheme: 'forest', current: 'Yaru-sage'}) === null);
check('Classic counts as no scheme', t({scheme: 'classic'}) === 'Yaru-blue');
check('a non-Yaru icon theme is never changed', t({current: 'Papirus'}) === null);
check('nothing to change: null', t({current: 'Yaru-blue'}) === null);
check('an unknown colour or accent changes nothing', t({choice: 'neon'}) === null && t({accent: 'chartreuse'}) === null);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
