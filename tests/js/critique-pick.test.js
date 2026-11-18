// tests/js/critique-pick.test.js: unit tests for tests/vm/critique/pick.js. Run with tests/js-test.sh.
import {describe, ownerOf, slug, cropRect, boxFromDrag} from '../vm/critique/pick.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

let d = describe([{type: 'St_Icon'}, {type: 'Gjs_ui_dash_DashIcon', app: 'Firefox'}, {type: 'St_Bin', name: 'ost-dock'}]);
check('a dock icon', d.label === 'Dock › Firefox' && d.owner === 'dock@ubuntu-ostrich');
d = describe([{type: 'St_Icon'}, {type: 'X', styleClass: 'show-apps'}, {type: 'St_Bin', name: 'ost-dock'}]);
check('the dock\'s app grid button', d.label === 'Dock › app grid button');
d = describe([{type: 'St_Icon'}, {type: 'Gjs_SiteButton', role: 'drawer@ubuntu-ostrich-claude'}]);
check('a drawer icon', d.label === 'Ostrich Drawer › claude icon' && d.owner === 'drawer@ubuntu-ostrich');
check('the drawer\'s + and ⌄', describe([{role: 'drawer@ubuntu-ostrich--add'}]).label === 'Ostrich Drawer › + (add a site)' &&
    describe([{role: 'drawer@ubuntu-ostrich--more'}]).label === 'Ostrich Drawer › ⌄ menu');
d = describe([{type: 'St_Label', text: 'mail'}, {type: 'St_Button', styleClass: 'ost-ws-button'}, {role: 'workspaces@ubuntu-ostrich'}]);
check('a workspace pill', d.label === 'Workspace bar › mail' && d.owner === 'workspaces@ubuntu-ostrich');
check('GNOME\'s own menus', describe([{styleClass: 'quick-settings'}]).label === 'Quick settings menu' &&
    describe([{styleClass: 'popup-menu-content'}]).label === 'Menu' && describe([{role: 'dateMenu'}]).label === 'Clock and calendar');
d = describe([{type: 'MetaSurfaceActorWayland'}], {appId: 'org.gnome.Nautilus.desktop', appName: 'Files', title: 'Home'});
check('a window', d.label === 'Window: Files — Home' && d.owner === 'org.gnome.Nautilus.desktop');
d = describe([{type: 'MetaSurfaceActorWayland'}], {appId: 'ubuntu_ostrich.drawer', site: 'Claude'});
check('the drawer window', d.label === 'Ostrich Drawer window (Claude)' && d.owner === 'drawer@ubuntu-ostrich');
check('unknown: its type', describe([{type: 'ClutterActor'}]).label === 'ClutterActor' && describe([]).label === 'the desktop');
check('blur backdrops belong to blur', ownerOf([{name: 'ost-blur-backdrop'}]) === 'blur@ubuntu-ostrich');

check('slugs', slug('Dock icons are TOO far apart!!') === 'dock-icons-are-too-far-apart' && slug('???') === 'note');
check('crop kept on screen', JSON.stringify(cropRect({x: 5, y: 5, width: 10, height: 10}, 20, {width: 100, height: 100})) === '{"x":0,"y":0,"width":35,"height":35}');
check('drag vs click', !boxFromDrag(10, 10, 100, 50).click && boxFromDrag(10, 10, 12, 13).click && boxFromDrag(100, 50, 10, 10).x === 10);

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
