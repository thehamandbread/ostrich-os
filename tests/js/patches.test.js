// tests/js/patches.test.js: _lib/patches.js. A target or field GNOME renamed is skipped, not fatal.
// Run with tests/js-test.sh.
import {Patches, hideStockTile, shellField} from '../../modules/gnome/extensions/_lib/patches.js';

let failures = 0;
function check(name, cond) {
    if (cond) {
        print(`ok - ${name}`);
    } else {
        failures++;
        print(`not ok - ${name}`);
    }
}

const target = {greet: () => 'hello'};
const p = new Patches();
const original = p.replace(target, 'greet', orig => () => `${orig()}!`);
check('patches a method', target.greet() === 'hello!' && original() === 'hello');
let threw = false, missing;
try {
    missing = p.replace(target, 'renamedInGnome51', orig => orig);
} catch {
    threw = true;
}
check('a missing target is skipped, not thrown', !threw && missing === null && !('renamedInGnome51' in target));
check('a missing object is skipped too', p.replace(undefined, 'x', o => o) === null);
p.restoreAll();
check('restoreAll puts the original back', target.greet() === 'hello');

const panel = {_leftBox: 'box'};
check('a private field is returned', shellField(panel, '_leftBox') === 'box');
check('a missing private field is null', shellField(panel, '_gone') === null && shellField(undefined, '_gone') === null);

// A stand-in for a GNOME quick-settings item: setting visible notifies only on a change, like Clutter.
class Item {
    constructor(visible) {
        this._v = visible;
        this._h = new Map();
        this._n = 0;
    }

    get visible() {
        return this._v;
    }

    set visible(v) {
        if (v === this._v)
            return;
        this._v = v;
        for (const f of this._h.values())
            f();
    }

    connect(_sig, f) {
        this._h.set(++this._n, f);
        return this._n;
    }

    disconnect(id) {
        this._h.delete(id);
    }
}
const tile = new Item(true), gone = new Item(false);
const qs = {_powerProfiles: {quickSettingsItems: [tile, gone]}, _bluetooth: null};
const restore = hideStockTile(qs, '_powerProfiles');
check('hideStockTile hides the visible tile', tile.visible === false && typeof restore === 'function');
tile.visible = true; // GNOME's sync after a profile change or a daemon restart
gone.visible = true;
check('GNOME showing them again is undone while hidden', tile.visible === false && gone.visible === false);
gone.visible = false; // already hidden by us: no notify, so this one is the documented shortcut
restore();
check('restore puts back what GNOME last asked for', tile.visible === true);
tile.visible = false;
check('after restore GNOME is in charge again', tile.visible === false && tile._h.size === 0);
check('a renamed field hides nothing', hideStockTile(qs, '_renamedInGnome51') === null);
check('a null field (no Bluetooth here) hides nothing', hideStockTile(qs, '_bluetooth') === null);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
