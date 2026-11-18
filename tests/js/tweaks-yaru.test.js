// tests/js/tweaks-yaru.test.js: the Yaru icon theme follows the style (tweaks/extension.js yaruFor).
// extension.js imports GNOME Shell's modules, which plain gjs can't load, so the function is loaded
// from its source text.
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
const src = new TextDecoder().decode(GLib.file_get_contents(`${here}/../../modules/gnome/extensions/tweaks/extension.js`)[1]);
const body = src.slice(src.indexOf('export function yaruFor'), src.indexOf('function run(argv)')).replace('export ', '');
// eslint-disable-next-line no-new-func
const yaruFor = new Function(`${body}; return yaruFor;`)();

check('dark adds -dark', yaruFor('Yaru-sage', true) === 'Yaru-sage-dark');
check('light drops it', yaruFor('Yaru-sage-dark', false) === 'Yaru-sage');
check('plain Yaru pairs with Yaru-dark', yaruFor('Yaru', true) === 'Yaru-dark' && yaruFor('Yaru-dark', false) === 'Yaru');
check('already right: unchanged', yaruFor('Yaru-blue-dark', true) === 'Yaru-blue-dark');
check('other themes are left alone', yaruFor('Papirus', true) === 'Papirus' && yaruFor('Adwaita', false) === 'Adwaita');

if (failures > 0)
    imports.system.exit(1);
