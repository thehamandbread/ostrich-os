// tests/js/focus-environments.test.js: unit tests for focus/environments.js. Run with tests/js-test.sh.
import {idFor, capture, validate, placementQueue, takePlace, allPlaced, isAllowed, drawerSet, withLayout, namedAt, withoutIndex} from '../../modules/gnome/extensions/focus/environments.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}
function throws(fn) {
    try {
        fn();
        return false;
    } catch {
        return true;
    }
}

check('ids from names', idFor('Video editing') === 'video-editing' && idFor('  School/Uni!! ') === 'school-uni');
check('no usable name', idFor('!!!') === null && idFor('') === null);

const env = capture('Video editing', [
    {app: 'org.gnome.Nautilus.desktop', monitor: 0, x: 0, y: 32, width: 960, height: 1048, maximized: false},
    {app: 'com.blackmagic.Resolve.desktop', monitor: 0, x: 960, y: 32, width: 960, height: 1048, maximized: false},
    {app: 'org.gnome.Nautilus.desktop', monitor: 1, x: 0, y: 0, width: 800, height: 600, maximized: true},
    {app: null, monitor: 0, x: 0, y: 0, width: 1, height: 1},
], {power: 'performance'});
check('capture groups windows by app, drops windows without an app',
    env.apps.length === 2 && env.apps[0].windows.length === 2 && env.power === 'performance');
const moved = withLayout({...env, dnd: true, focus: {on: true, allowed: ['org.gnome.Nautilus.desktop']}},
    [{app: 'org.gnome.TextEditor.desktop', monitor: 0, x: 10, y: 40, width: 500, height: 400, maximized: false}]);
check('closing saves the windows as they are, keeping focus, power and DND',
    moved.apps.length === 1 && moved.apps[0].app === 'org.gnome.TextEditor.desktop' &&
    moved.dnd && moved.focus.on && moved.power === 'performance' && moved.name === 'Video editing');
check('closing an emptied workspace keeps what was saved', withLayout(env, []) === env);
check('naming a workspace pads the list', JSON.stringify(namedAt(['A'], 3, 'School')) === '["A","","","School"]');
check('naming keeps the others', JSON.stringify(namedAt(['A', 'B'], 0, 'X')) === '["X","B"]');
check('removing a workspace moves the later names down',
    JSON.stringify(withoutIndex(['A', 'School', 'C'], 1)) === '["A","C"]');
check('removing the last named one trims the list', JSON.stringify(withoutIndex(['A', '', 'S'], 2)) === '["A"]');
check('capture round-trips through JSON', JSON.stringify(validate(JSON.parse(JSON.stringify(env)))) === JSON.stringify(env));

check('rejects a bad app id', throws(() => validate({...env, apps: [{app: '../../etc/passwd', windows: []}]})));
check('rejects bad geometry', throws(() => validate({...env, apps: [{app: 'a.desktop', windows: [{monitor: 0, x: 'x', y: 0, width: 1, height: 1}]}]})));
check('rejects an unknown power mode', throws(() => validate({...env, power: 'turbo'})));
check('rejects a future format', throws(() => validate({...env, version: 2})));
check('drops bad allow-list entries', validate({...env, focus: {on: true, allowed: ['a.desktop', 'rm -rf']}}).focus.allowed.length === 1);

const q = placementQueue(env);
const first = takePlace(q, 'org.gnome.Nautilus.desktop');
const second = takePlace(q, 'org.gnome.Nautilus.desktop');
check('windows take their app\'s saved places in order', first.width === 960 && second.maximized && second.monitor === 1);
check('a third window has no saved place', takePlace(q, 'org.gnome.Nautilus.desktop') === null);
check('an unknown app has no saved place', takePlace(q, 'x.desktop') === null);
check('not all placed until Resolve is', !allPlaced(q));
takePlace(q, 'com.blackmagic.Resolve.desktop');
check('all placed', allPlaced(q));

const withDrawer = capture('School', [{app: 'org.gnome.Nautilus.desktop', monitor: 0, x: 0, y: 0, width: 9, height: 9}],
    {drawer: {sites: ['claude', 'gmail', 'gmail', '../x', 7], keep: ['gmail', 'youtube']}});
check('drawer set kept, bad and repeated ids dropped, keep only from its sites',
    JSON.stringify(withDrawer.drawer) === JSON.stringify({sites: ['claude', 'gmail'], keep: ['gmail']}));
check('drawer set round-trips', JSON.stringify(validate(JSON.parse(JSON.stringify(withDrawer)))) === JSON.stringify(withDrawer));
check('no drawer set: null', env.drawer === null && drawerSet('x') === null);

check('empty allow-list allows everything', isAllowed([], 'anything.desktop'));
check('allow-list allows only its apps', isAllowed(['a.desktop'], 'a.desktop') && !isAllowed(['a.desktop'], 'b.desktop'));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
