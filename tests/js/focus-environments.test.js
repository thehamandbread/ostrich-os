// tests/js/focus-environments.test.js: unit tests for focus/environments.js. Run with tests/js-test.sh.
import {idFor, capture, validate, cleanOpen, cleanCwd, FORMAT_VERSION, MAX_OPEN_PER_WORKSPACE, placementQueue, takePlace, allPlaced, isAllowed, drawerSet, withLayout, namedAt, withoutIndex} from '../../modules/gnome/extensions/focus/environments.js';

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
check('rejects a future format', throws(() => validate({...env, version: 3})));
check('rejects version 0', throws(() => validate({...env, version: 0})));
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

// ---- what the windows had open (format 2) ----
check('the format is 2 and a version 1 file is still read',
    FORMAT_VERSION === 2 && validate({...env, version: 1}).version === 2);
check('a version 1 window has no saved state', validate({...env, version: 1}).apps[0].windows.every(w => !('open' in w) && !('cwd' in w)));
const winOf = (app, extra) => ({app, monitor: 0, x: 0, y: 0, width: 9, height: 9, ...extra});
const withState = capture('State', [
    winOf('org.gnome.Nautilus.desktop', {open: ['file:///home/me/Videos']}),
    winOf('com.mitchellh.ghostty.desktop', {cwd: '/home/me/code'}),
    winOf('firefox.desktop', {open: ['https://example.org/a?b=1#c', 'http://localhost:8000/']}),
]);
check('open and cwd are saved with their window',
    withState.apps[0].windows[0].open[0] === 'file:///home/me/Videos' &&
    withState.apps[1].windows[0].cwd === '/home/me/code' && withState.apps[2].windows[0].open.length === 2);
check('state round-trips through JSON', JSON.stringify(validate(JSON.parse(JSON.stringify(withState)))) === JSON.stringify(withState));
check('closing keeps the windows\' state', withLayout(env, [winOf('firefox.desktop', {open: ['https://a.example/']})]).apps[0].windows[0].open[0] === 'https://a.example/');
const bad = ['javascript:alert(1)', 'data:text/html,x', 'about:config', 'file://host/etc/passwd', 'ftp://x/y', '/etc/passwd',
    'https://a b', 'https://a\nb', 'https://ok.example/', 7, null, 'file:///ok/path'];
check('only web pages and local files are kept', JSON.stringify(cleanOpen(bad)) === JSON.stringify(['https://ok.example/', 'file:///ok/path']));
check('a long address is dropped', cleanOpen(['https://x/' + 'a'.repeat(5000)]).length === 0);
check('at most 40 addresses a window', cleanOpen(Array.from({length: 100}, (_, i) => `https://e.example/${i}`)).length === 40);
const many = {...env, apps: [{app: 'a.desktop', windows: Array.from({length: 8}, () => ({monitor: 0, x: 0, y: 0, width: 9, height: 9,
    open: Array.from({length: 40}, (_, i) => `https://e.example/${i}`)}))}]};
check('at most 200 addresses in a workspace',
    validate(many).apps[0].windows.reduce((n, w) => n + (w.open?.length ?? 0), 0) === MAX_OPEN_PER_WORKSPACE);
check('not a list: nothing', cleanOpen('https://x/').length === 0 && cleanOpen(undefined).length === 0);
check('cwd: absolute only', cleanCwd('/home/me') === '/home/me' && cleanCwd('home/me') === '' && cleanCwd('~') === '' && cleanCwd(7) === '');
check('cwd: no .. and no control characters', cleanCwd('/home/../etc') === '' && cleanCwd('/a\nb') === '' && cleanCwd('/a\u0000b') === '');
check('a window only has the state it was given', !('cwd' in withState.apps[0].windows[0]) && !('open' in withState.apps[1].windows[0]));

// ---- a failed read doesn't wipe what was saved ----
const saved = capture('Keep', [winOf('org.gnome.Nautilus.desktop', {open: ['file:///a']}), winOf('firefox.desktop', {open: ['https://x.example/']}),
    winOf('org.gnome.Nautilus.desktop', {open: ['file:///b']})]);
const kept = withLayout(saved, [winOf('org.gnome.Nautilus.desktop', {}), winOf('firefox.desktop', {open: ['https://new.example/']}),
    winOf('org.gnome.Nautilus.desktop', {open: ['file:///c']})]);
check('a window nothing was read for keeps its old contents', kept.apps[0].windows[0].open[0] === 'file:///a');
check('a window that was read has its new contents', kept.apps[1].windows[0].open[0] === 'https://new.example/' && kept.apps[0].windows[1].open[0] === 'file:///c');
check('a new window with nothing has nothing', !('open' in withLayout(saved, [winOf('org.gnome.Nautilus.desktop', {}), winOf('org.gnome.Nautilus.desktop', {}), winOf('org.gnome.Nautilus.desktop', {}), winOf('org.gnome.Nautilus.desktop', {})]).apps[0].windows[3]));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
