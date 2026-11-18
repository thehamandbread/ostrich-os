// tests/js/tray-pixmap.test.js: unit tests for tray/pixmap.js. Run with tests/js-test.sh.
import {argbToRgba, parseService, pickPixmap, stripMnemonic} from '../../modules/gnome/extensions/tray/pixmap.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

const px = (w, h) => [w, h, new Uint8Array(w * h * 4)];
check('pick smallest pixmap at least the size', pickPixmap([px(16, 16), px(32, 32), px(64, 64)], 24)[0] === 32);
check('pick largest when all are smaller', pickPixmap([px(16, 16), px(22, 22)], 48)[0] === 22);
check('ignore truncated pixmaps', pickPixmap([[32, 32, new Uint8Array(10)]], 16) === null);
check('no pixmaps gives null', pickPixmap([], 16) === null);

const rgba = argbToRgba(new Uint8Array([0xff, 0x10, 0x20, 0x30, 0x80, 1, 2, 3]));
check('ARGB to RGBA reorders channels', [...rgba].join() === [0x10, 0x20, 0x30, 0xff, 1, 2, 3, 0x80].join());

check('service as bus name', JSON.stringify(parseService(':1.42', ':1.42')) === JSON.stringify({busName: ':1.42', objectPath: '/StatusNotifierItem'}));
check('service as object path uses the sender', JSON.stringify(parseService('/org/ayatana/NotificationItem/nm', ':1.7')) === JSON.stringify({busName: ':1.7', objectPath: '/org/ayatana/NotificationItem/nm'}));
check('service as name/path', parseService('org.kde.StatusNotifierItem-1-1/Item', ':1.9').objectPath === '/Item');

check('mnemonic stripped', stripMnemonic('_Quit') === 'Quit');
check('double underscore kept', stripMnemonic('my__file') === 'my_file');
check('null label', stripMnemonic(null) === '');

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
