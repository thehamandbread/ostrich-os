// tests/js/tweaks-nowplaying.test.js: which player the now-playing pill shows, and its text
// (tweaks/nowplaying.js). nowplaying.js imports GNOME Shell's modules, which plain gjs can't load,
// so the pure helpers are loaded from its source text.
import GLib from 'gi://GLib';
import {fromMetadata, playingApps} from '../../modules/gnome/extensions/_lib/mpris.js';

let failures = 0;
function check(name, cond) {
    if (cond) {
        print(`ok - ${name}`);
    } else {
        failures++;
        print(`not ok - ${name}`);
    }
}

const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
const src = new TextDecoder().decode(GLib.file_get_contents(`${here}/../../modules/gnome/extensions/tweaks/nowplaying.js`)[1]);
const body = src.slice(src.indexOf('export function pickPlayer'), src.indexOf('// ---- the pill')).replaceAll('export ', '');
// eslint-disable-next-line no-new-func
const {pickPlayer, pillText} = new Function(`const MAX_CHARS = 24; ${body}; return {pickPlayer, pillText};`)();

const p = (name, status, title, artist = '') => ({name, status, title, artist});
check('nothing playing: no pill', pickPlayer([]) === null);
check('playing wins over paused', pickPlayer([p('a', 'Paused', 'A'), p('b', 'Playing', 'B')]).name === 'b');
check('paused with a title shows', pickPlayer([p('a', 'Paused', 'A')]).name === 'a');
check('stopped never shows', pickPlayer([p('a', 'Stopped', 'A')]) === null);
check('an empty player (no title) never shows', pickPlayer([p('drawer', 'Playing', '')]) === null);
check('the title only (the artist is in the drop-down)', pillText(p('a', 'Playing', 'Song', 'Band')) === 'Song');
const long = pillText(p('a', 'Playing', 'x'.repeat(200)));
check('a long title is cut to 24 characters', [...long].length === 24 && long.endsWith('…'));
check('emoji are not cut in half', [...pillText(p('a', 'Playing', '🎵'.repeat(40)))].every(c => c === '🎵' || c === '…'));
const md = fromMetadata({'xesam:title': ' Song ', 'xesam:artist': ['A', 'B', 3]});
check('metadata: title trimmed, artists joined', md.title === 'Song' && md.artist === 'A, B');
check('metadata: missing fields are empty', fromMetadata({}).title === '' && fromMetadata(null).artist === '');
const apps = playingApps([{status: 'Playing', desktopEntry: 'firefox'}, {status: 'Paused', desktopEntry: 'spotify'},
    {status: 'Playing', desktopEntry: 'org.gnome.Totem.desktop'}, {status: 'Playing', desktopEntry: ''}]);
check('playing apps: by desktop id, playing only, no entry left out',
    apps.size === 2 && apps.has('firefox.desktop') && apps.has('org.gnome.Totem.desktop'));

if (failures > 0)
    imports.system.exit(1);
