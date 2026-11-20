// tests/js/monitor-nvidia.test.js: unit tests for monitor/nvidia.js parsing. Run with tests/js-test.sh.
import {appFromCgroup, isOwnApp} from '../../modules/gnome/extensions/monitor/nvidia.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

const flatpak = appFromCgroup('/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-com.lunarclient.LunarClient-2060268014.scope');
check('flatpak scope', flatpak?.kind === 'flatpak' && flatpak.id === 'com.lunarclient.LunarClient' && flatpak.name === 'LunarClient');

const desktop = appFromCgroup('/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-org.blender.Blender-12345.scope');
check('gnome-launched desktop app', desktop?.kind === 'desktop' && desktop.id === 'org.blender.Blender');

const escaped = appFromCgroup('app-gnome-google\\x2dchrome-999.scope');
check('escaped dash in id', escaped?.id === 'google-chrome');

const tab = appFromCgroup('app-ghostty-surface-transient-8839.scope');
check('terminal tab has no kind (signal pids only)', tab?.kind === null && tab.id === 'ghostty');

const snap = appFromCgroup('snap.steam.steam-1234.scope');
check('snap scope', snap?.kind === 'snap' && snap.id === 'steam');

check('session scope is not an app', appFromCgroup('/user.slice/user-1000.slice/session-2.scope') === null);

const drawer = appFromCgroup('app-gnome-ostrich\\x2ddrawer-1732465.scope');
check('the drawer scope is read as ostrich-drawer', drawer?.id === 'ostrich-drawer');
check('the drawer, Store and Settings are Ostrich\'s own', isOwnApp(drawer) && isOwnApp({id: 'ostrich-store'}) && isOwnApp({id: 'ubuntu_ostrich.drawer'}));
check('other apps are not', !isOwnApp(desktop) && !isOwnApp(flatpak) && !isOwnApp(null) && !isOwnApp({id: 'not-ostrich-at-all'}));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
