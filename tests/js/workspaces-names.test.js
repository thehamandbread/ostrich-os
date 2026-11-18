// tests/js/workspaces-names.test.js: unit tests for workspaces/names.js. Run with tests/js-test.sh.
import {accessibleName, associate, label, parseMap, smartName, moveName, removeName, visibleIndexes} from '../../modules/gnome/extensions/workspaces/names.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

// The original machine's map shape: {"firefox_firefox": ["1"], "com.mitchellh.ghostty": ["2"], ...}
const map = {'firefox_firefox': ['1'], 'com.mitchellh.ghostty': ['2'], 'org.signal.Signal': ['n']};
check('smart name from the first app with a free name', smartName(map, ['com.mitchellh.ghostty'], []) === '2');
check('no association gives null', smartName(map, ['org.gnome.Nautilus'], []) === null);
check('a name in use elsewhere is skipped', smartName(map, ['firefox_firefox'], ['1']) === null);
check('later candidates are tried', smartName({a: ['x', 'y']}, ['a'], ['x']) === 'y');

const next = associate(map, ['firefox_firefox', 'org.gnome.Nautilus'], 'web', ['2', 'n']);
check('associate appends the new name', next['org.gnome.Nautilus'].join() === 'web');
check('associate drops names no longer in use', next['firefox_firefox'].join() === 'web');
check('associate keeps names still in use', associate({a: ['2']}, ['a'], 'z', ['2']).a.join() === '2,z');
check('associate leaves other apps alone', next['com.mitchellh.ghostty'].join() === '2');
check('associate does not mutate the input', map['firefox_firefox'].join() === '1');

check('label uses the name', label(['mail', ''], 0) === 'mail');
check('label falls back to the number', label(['mail', ''], 1) === '2' && label([], 4) === '5');
check('screen reader name: number, name, current', accessibleName(['mail', ''], 0, true) === 'Workspace 1: mail, current' &&
    accessibleName(['mail', ''], 1, false) === 'Workspace 2' && accessibleName([], 4, false) === 'Workspace 5');

check('parseMap reads JSON', parseMap('{"a":["1"]}').a[0] === '1');
check('parseMap tolerates junk', Object.keys(parseMap('nope')).length === 0 && Object.keys(parseMap('[1]')).length === 0);

const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
check('a moved workspace keeps its name', eq(moveName(['mail', 'code', 'web'], 0, 2), ['code', 'web', 'mail']));
check('moving past the named ones', eq(moveName(['mail'], 0, 2), ['', '', 'mail']) && eq(moveName(['', 'x'], 1, 0), ['x']));
check('removing shifts the names after it', eq(removeName(['a', 'b', 'c'], 1), ['a', 'c']) && eq(removeName(['a', 'b'], 1), ['a']));
const vis = o2 => visibleIndexes({count: 4, active: 1, empty: [false, false, true, true], style: 'all', showEmpty: true, ...o2});
check('all workspaces', eq(vis({}), [0, 1, 2, 3]));
check('empty ones hidden (not the active one)', eq(vis({showEmpty: false}), [0, 1]) && eq(vis({showEmpty: false, active: 3}), [0, 1, 3]));
check('only the current one', eq(vis({style: 'current'}), [1]));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
