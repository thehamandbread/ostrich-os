// tests/js/monitor-keepoff.test.js: unit tests for monitor/keepoff.js. Run with tests/js-test.sh.
// keepoff.js reads the XDG dirs when it loads, so they point at a temporary folder first.
import GLib from 'gi://GLib';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

const tmp = GLib.dir_make_tmp('keepoff-XXXXXX');
GLib.setenv('XDG_CONFIG_HOME', `${tmp}/config`, true);
GLib.setenv('XDG_DATA_HOME', `${tmp}/data`, true);
const {addPrefix, removePrefix, apply, undo, list} = await import('../../modules/gnome/extensions/monitor/keepoff.js');

const plain = '[Desktop Entry]\nType=Application\nName=Test\nExec=test %U\n\n[Desktop Action new]\nExec=test --new\n';
const kept = addPrefix(plain);
check('every Exec= line gets the env prefix', kept.split('\n').filter(l => l.startsWith('Exec=env ')).length === 2);
check('marker under the header', kept.split('\n')[1] === 'X-NvidiaPower-KeepOff=true');
check('adding twice changes nothing', addPrefix(kept) === kept);
check('prefix round trip', removePrefix(kept) === plain);

const dbus = '[Desktop Entry]\nName=Test\nExec=test\nDBusActivatable=true\n';
const keptDbus = addPrefix(dbus);
check('D-Bus activation turned off', keptDbus.split('\n').includes('DBusActivatable=false') && !keptDbus.split('\n').includes('DBusActivatable=true'));
check('D-Bus activation round trip', removePrefix(keptDbus) === dbus);

// apply twice, then undo: our user copy goes away. gjs has already read XDG_DATA_DIRS, so the
// app's own launcher sits in a subfolder of the user's (applications/example/KeepOffTest.desktop
// has the id example-KeepOffTest), and the copy keepoff.js writes is a different file.
const id = 'example-KeepOffTest';
GLib.mkdir_with_parents(`${tmp}/data/applications/example`, 0o755);
GLib.file_set_contents(`${tmp}/data/applications/example/KeepOffTest.desktop`, plain);
const userCopy = `${tmp}/data/applications/${id}.desktop`;
await apply({kind: 'desktop', id}, 'Test');
check('first apply creates the user copy', list()[id]?.createdFile === true && GLib.file_test(userCopy, GLib.FileTest.EXISTS));
await apply({kind: 'desktop', id}, 'Test');
check('second apply keeps createdFile', list()[id]?.createdFile === true);
await undo(id);
check('undo removes our copy', !GLib.file_test(userCopy, GLib.FileTest.EXISTS) && !(id in list()));
GLib.spawn_sync(null, ['rm', '-rf', tmp], null, GLib.SpawnFlags.SEARCH_PATH, null);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
