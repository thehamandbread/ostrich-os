// tests/js/focus-appstate.test.js: unit tests for focus/appstate.js and focus/mozlz4.js. Run with tests/js-test.sh.
import {kindOf, firefoxRoots, baseArgv, launchArgv, scopedArgv, pairWindows, firefoxWindows, assignFolders} from '../../modules/gnome/extensions/focus/appstate.js';
import {lz4Block, mozlz4Text, mozlz4Literal} from '../../modules/gnome/extensions/focus/mozlz4.js';

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

// ---- which app is which ----
check('Files', kindOf('org.gnome.Nautilus.desktop') === 'files');
check('terminals', ['com.mitchellh.ghostty.desktop', 'org.gnome.Ptyxis.desktop', 'org.gnome.Terminal.desktop', 'kitty.desktop'].every(i => kindOf(i) === 'terminal'));
check('Firefox and its forks', ['firefox.desktop', 'firefox_firefox.desktop', 'org.mozilla.firefox.desktop', 'app.zen_browser.zen.desktop', 'io.gitlab.librewolf-community.desktop'].every(i => kindOf(i) === 'firefox'));
check('Chrome and its kin', ['google-chrome.desktop', 'com.google.Chrome.desktop', 'chromium_chromium.desktop', 'com.brave.Browser.desktop', 'microsoft-edge.desktop'].every(i => kindOf(i) === 'chromium'));
check('anything else saves nothing inside', kindOf('org.gnome.Calculator.desktop') === null && kindOf('') === null && kindOf(null) === null);

check('profile folders by browser', firefoxRoots('app.zen_browser.zen.desktop').some(r => r.includes('zen')) &&
    firefoxRoots('firefox_firefox.desktop').some(r => r.startsWith('snap/')) && firefoxRoots('google-chrome.desktop').length === 0);

// ---- the command line of an app ----
check('field codes are dropped', JSON.stringify(baseArgv(['firefox', '%u'])) === '["firefox"]' && JSON.stringify(baseArgv(['nautilus', '--new-window', '%U'])) === '["nautilus","--new-window"]');
check("Flatpak's file markers are dropped", JSON.stringify(baseArgv(['flatpak', 'run', '--branch=stable', 'app.zen_browser.zen', '@@u', '%U', '@@'])) === '["flatpak","run","--branch=stable","app.zen_browser.zen"]');
check('a literal percent stays', baseArgv(['x', '100%%']).length === 2);

// ---- launching a window with its state ----
const ff = ['/snap/bin/firefox'];
check('Firefox opens the first page in a new window and the rest as tabs of it',
    JSON.stringify(launchArgv('firefox', ff, {open: ['https://a/', 'https://b/', 'https://c/']})) === '["/snap/bin/firefox","--new-window","https://a/","--new-tab","https://b/","--new-tab","https://c/"]');
check('Chrome takes its pages as plain arguments', JSON.stringify(launchArgv('chromium', ['google-chrome'], {open: ['https://a/', 'https://b/']})) === '["google-chrome","--new-window","https://a/","https://b/"]');
check('Files opens its folder in a new window', JSON.stringify(launchArgv('files', ['nautilus'], {open: ['file:///home/me/x', 'file:///other']})) === '["nautilus","--new-window","file:///home/me/x"]');
check('Ghostty opens in its folder', JSON.stringify(launchArgv('terminal', ['ghostty', '--gtk-single-instance=true'], {cwd: '/home/me/code'})) === '["ghostty","--gtk-single-instance=true","--working-directory=/home/me/code"]');
check('Flatpak Zen: the flags come after the app id', launchArgv('firefox', ['flatpak', 'run', 'app.zen_browser.zen'], {open: ['https://z/']}).slice(-3).join(' ') === 'app.zen_browser.zen --new-window https://z/');
check('the first page alone: no --new-tab', !launchArgv('firefox', ff, {open: ['https://a/']}).includes('--new-tab'));
check('nothing to pass: launched as before', launchArgv('firefox', ff, {}) === null && launchArgv('terminal', ['ghostty'], {}) === null && launchArgv(null, ff, {open: ['https://a/']}) === null && launchArgv('files', [], {open: ['file:///x']}) === null);
check('an unknown terminal is launched as before', launchArgv('terminal', ['mystery-term'], {cwd: '/home/me'}) === null);

check('a launch runs in a scope named like GNOME\'s', JSON.stringify(scopedArgv('com.mitchellh.ghostty.desktop', ['ghostty', '--working-directory=/x'], 'ab12cd')) ===
    '["systemd-run","--user","--scope","--quiet","--collect","--unit=app-gnome-com.mitchellh.ghostty-ab12cd.scope","ghostty","--working-directory=/x"]');
check('Flatpak is left alone (it makes its own scope)', JSON.stringify(scopedArgv('app.zen_browser.zen.desktop', ['flatpak', 'run', 'app.zen_browser.zen'], 'ab12cd')) === '["flatpak","run","app.zen_browser.zen"]');
check('an odd id makes a safe unit name', scopedArgv('we ird/id.desktop', ['x'], 'ab').some(w => w === '--unit=app-gnome-we_ird_id-ab.scope'));

// ---- mozlz4 ----
const text = JSON.stringify({windows: [{tabs: [{entries: [{url: 'https://example.org/', title: 'Example'}]}]}]});
check('a mozlz4 file round-trips', mozlz4Text(mozlz4Literal(text)) === text);
check('a longer one (length bytes)', mozlz4Text(mozlz4Literal('x'.repeat(1000))) === 'x'.repeat(1000));
// "abcabcabcabc" as one literal "abc" and a match of 9 bytes at offset 3, then 1 trailing literal... built by hand:
// token 0x35 (3 literals, match 5+4), "abc", offset 3, then a final token with 0 literals.
const withMatch = new Uint8Array([0x35, 0x61, 0x62, 0x63, 0x03, 0x00, 0x00]);
check('an LZ4 match, overlapping', new TextDecoder().decode(lz4Block(withMatch, 12)) === 'abcabcabcabc');
check('not a mozlz4 file', throws(() => mozlz4Text(new TextEncoder().encode('{"windows": []} plain json'))));
check('a match before the start is refused', throws(() => lz4Block(new Uint8Array([0x05, 0x61, 0x09, 0x00]), 10)));
check('a size that is too big is refused', throws(() => lz4Block(new Uint8Array([0x10, 0x61]), 1 << 30)));
check('truncated data is refused', throws(() => lz4Block(new Uint8Array([0x50, 0x61]), 5)));

// ---- reading a Firefox session ----
const tab = (url, title, extra = {}) => ({entries: [{url: 'https://old.example/', title: 'old'}, {url, title}], index: 2, ...extra});
const session = {windows: [
    {tabs: [tab('https://a.example/', 'Page A'), tab('https://pin.example/', 'Pinned', {pinned: true}), tab('about:newtab', 'New Tab'), tab('https://c.example/', 'Page C')], selected: 4},
    {tabs: [tab('https://other.example/', 'Other')], selected: 1},
    {tabs: [tab('about:blank', '')], selected: 1},
]};
const wins = firefoxWindows(session);
check('a session window: its pages, pinned first, only web pages',
    JSON.stringify(wins[0].uris) === JSON.stringify(['https://pin.example/', 'https://a.example/', 'https://c.example/']));
check('its title is the selected tab\'s', wins[0].title === 'Page C' && wins[1].title === 'Other');
check('a window with nothing to save is dropped', wins.length === 2);
check('the page of the current history entry, not the first', wins[1].uris[0] === 'https://other.example/');
check('a broken session is empty', firefoxWindows(null).length === 0 && firefoxWindows({windows: 'x'}).length === 0 && firefoxWindows({windows: [{tabs: 5}]}).length === 0);

// ---- which browser window is which ----
const titles = ['Page C', 'Other'];
check('matched by title, the browser name after it', JSON.stringify(pairWindows(titles, ['Other — Mozilla Firefox', 'Page C — Mozilla Firefox'])) === '[1,0]');
check('a title that changed pairs when one is left on each side', JSON.stringify(pairWindows(['Old title'], ['New title — Zen Browser'])) === '[0]');
check('more than one left is not guessed', JSON.stringify(pairWindows(['A', 'B', 'C'], ['x — Firefox', 'y — Firefox'])) === '[null,null]');
check('windows on other workspaces are not in the list: the extra session windows stay unused', JSON.stringify(pairWindows(['A', 'B', 'C'], ['B — Firefox'])) === '[1]');
check('the same title twice pairs each once', JSON.stringify(pairWindows(['Same', 'Same'], ['Same — Firefox', 'Same — Firefox'])) === '[0,1]');
check('an empty session title never matches by title', JSON.stringify(pairWindows(['', 'B'], ['B — Firefox', 'Z — Firefox'])) === '[1,0]');

// ---- which folder each terminal was in ----
const home = '/home/me';
check('by title: the folder\'s name', JSON.stringify(assignFolders(['code', 'notes'], ['/home/me/notes', '/home/me/code'], home)) === '["/home/me/code","/home/me/notes"]');
check('~ in a title is the home folder', JSON.stringify(assignFolders(['me@host: ~'], ['/home/me/x', home], home)) === '["/home/me"]');
check('titles that say nothing: the folders in order', JSON.stringify(assignFolders(['a', 'b'], ['/one', '/two'], home)) === '["/one","/two"]');
check('more windows than folders: the rest get none', JSON.stringify(assignFolders(['a', 'b'], ['/one'], home)) === '[null,null]');
check('more folders than windows (others are on other workspaces): only title matches', JSON.stringify(assignFolders(['code'], ['/home/me/music', '/home/me/code'], home)) === '["/home/me/code"]');
check('...and with no title match, none', JSON.stringify(assignFolders(['zzz'], ['/home/me/music', '/home/me/code'], home)) === '[null]');
check('no folders: none', JSON.stringify(assignFolders(['a'], [], home)) === '[null]');

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
