// tests/js/dock-logic.test.js: unit tests for dock/docklogic.js. Run with tests/js-test.sh.
import {clickAction, nextWindow, dotCount, hasDockWindow, mergeLauncherEntry, appIdFromUri, countText} from '../../modules/gnome/extensions/dock/docklogic.js';

let failures = 0;
function check(name, cond) {
    print(`${cond ? 'ok' : 'not ok'} - ${name}`);
    if (!cond)
        failures++;
}

const S = 'focus-or-minimize', C = 'focus-or-cycle';
check('not running: launch', clickAction({running: false, focused: false, windows: 0}, S) === 'launch');
check('running elsewhere (no windows here): activate', clickAction({running: true, focused: false, windows: 0}, S) === 'activate');
check('not focused: activate', clickAction({running: true, focused: false, windows: 1}, S) === 'activate');
check('focused, one window: minimize', clickAction({running: true, focused: true, windows: 1}, S) === 'minimize');
check('focused, several windows: cycle', clickAction({running: true, focused: true, windows: 3}, S) === 'cycle');
check('cycle setting, one window: stays', clickAction({running: true, focused: true, windows: 1}, C) === 'activate');
check('plain focus never minimizes', clickAction({running: true, focused: true, windows: 2}, 'focus') === 'activate');

check('next window wraps', nextWindow(['a', 'b', 'c'], 'c') === 'a' && nextWindow(['a', 'b'], 'a') === 'b');
check('previous window wraps', nextWindow(['a', 'b', 'c'], 'a', -1) === 'c');
check('unknown current: the first', nextWindow(['a', 'b'], 'z') === 'a' && nextWindow([], 'a') === null);

check('dots: one per window, at most 4', dotCount(0) === 0 && dotCount(2) === 2 && dotCount(9) === 4);

let e = mergeLauncherEntry(undefined, {'count': 3, 'count-visible': true});
check('launcher count shown', countText(e) === '3');
e = mergeLauncherEntry(e, {'progress': 0.5, 'progress-visible': true});
check('updates merge (count kept, progress added)', e.count === 3 && e.progress === 0.5 && e.progressVisible);
e = mergeLauncherEntry(e, {'count-visible': false});
check('hidden count: no badge', countText(e) === '');
check('large counts', countText(mergeLauncherEntry({}, {'count': 250, 'count-visible': true})) === '99+');
check('progress clamped', mergeLauncherEntry({}, {progress: 7}).progress === 1);
check('app ids from URIs', appIdFromUri('application://firefox_firefox.desktop') === 'firefox_firefox.desktop' && appIdFromUri('file:///x') === null);

check('an app with a window is in the dock', hasDockWindow([{skip_taskbar: false}]));
check('a tray-only app (no windows) is not', !hasDockWindow([]));
check('a window that skips the taskbar does not count', !hasDockWindow([{skip_taskbar: true}]) && hasDockWindow([{skip_taskbar: true}, {skip_taskbar: false}]));

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
