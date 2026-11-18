// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/nowplaying.js: what's playing, beside the clock (council verdict 2026-10-24, M7; owner,
// 2026-11-02). It pops out of the clock bubble when something starts playing and goes back into it
// HIDE_AFTER_MS after playback pauses or stops; a click opens its own drop-down with previous,
// play/pause and next. MPRIS over D-Bus, followed by signals: one timer only while it waits to go.
// On by default (`now-playing-pill`), and invisible until something plays. It floats just right of
// the clock instead of sitting in the bar's layout, so the clock never moves when it comes and goes.
// GNOME's own media card in the clock menu stays.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {popOut, retreat} from './_lib/motion.js';
import {Players} from './_lib/mpris.js';

const MAX_CHARS = 32;
const HIDE_AFTER_MS = 6000; // paused or stopped this long: back into the clock
const GAP = 6; // between the clock and the pill

// ---- pure helpers (tests/js/tweaks-nowplaying.test.js) ----

// The player to show, from [{name, status, title, artist}]: one that's playing, else one paused on a
// track with a title. Empty players (no title: a page that only registered a media session) never.
export function pickPlayer(players) {
    const titled = players.filter(p => p.title);
    return titled.find(p => p.status === 'Playing') ?? titled.find(p => p.status === 'Paused') ?? null;
}

// "Title · Artist", shortened to max characters (whole characters, not halves of an emoji).
export function pillText(p, max = MAX_CHARS) {
    const text = p.artist ? `${p.title} · ${p.artist}` : p.title;
    const chars = [...text];
    return chars.length > max ? `${chars.slice(0, max - 1).join('').trimEnd()}…` : text;
}

// ---- the pill ----


const NowPlaying = GObject.registerClass({
    Signals: {'place': {}}, // shown: the owner puts it beside the clock
}, class NowPlaying extends PanelMenu.Button {
    _init() {
        super._init(0.5, 'Now playing');
        this.add_style_class_name('ost-now-playing');
        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        // Sized here: it floats beside the bar, outside the bar's own icon rules.
        this._icon = new St.Icon({icon_name: 'media-playback-start-symbolic', icon_size: 12, y_align: Clutter.ActorAlign.CENTER});
        this._label = new St.Label({y_align: Clutter.ActorAlign.CENTER});
        box.add_child(this._icon);
        box.add_child(this._label);
        this.add_child(box);

        this._title = new St.Label({style_class: 'ost-now-playing-title'});
        this._artist = new St.Label({style_class: 'ost-now-playing-artist'});
        const info = new PopupMenu.PopupBaseMenuItem({reactive: false});
        const text = new St.BoxLayout({vertical: true});
        text.add_child(this._title);
        text.add_child(this._artist);
        info.add_child(text);
        this.menu.addMenuItem(info);
        const controls = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const row = new St.BoxLayout({x_expand: true, x_align: Clutter.ActorAlign.CENTER, style_class: 'ost-now-playing-controls'});
        const button = (icon, name, action) => {
            const b = new St.Button({
                style_class: 'button ost-now-playing-button',
                child: new St.Icon({icon_name: icon, icon_size: 16}),
                accessible_name: name,
                can_focus: true,
            });
            b.connect('clicked', () => this._player?.[`${action}Remote`]?.());
            row.add_child(b);
            return b;
        };
        this._prev = button('media-skip-backward-symbolic', 'Previous', 'Previous');
        this._play = button('media-playback-pause-symbolic', 'Pause', 'PlayPause');
        this._next = button('media-skip-forward-symbolic', 'Next', 'Next');
        controls.add_child(row);
        this.menu.addMenuItem(controls);

        this._player = null;
        this._hideId = 0;
        this._shown = false;
        this.container.visible = false; // PanelMenu.Button lives in its container (St.Bin)
        this._players = new Players(() => this._refresh());
    }

    _refresh() {
        const pick = pickPlayer(this._players.list());
        this._player = pick?.proxy ?? null;
        const playing = pick?.status === 'Playing';
        this._show(playing);
        if (!pick) {
            this.menu.close(); // the player quit: nothing left to control, so let the pill go back
            return;
        }
        this._label.text = pillText(pick);
        this._icon.icon_name = playing ? 'media-playback-start-symbolic' : 'media-playback-pause-symbolic';
        this.accessible_name = `${playing ? 'Playing' : 'Paused'}: ${pillText(pick, 200)}`;
        this._title.text = pick.title;
        this._artist.text = pick.artist;
        this._artist.visible = !!pick.artist;
        this._play.child.icon_name = playing ? 'media-playback-pause-symbolic' : 'media-playback-start-symbolic';
        this._play.accessible_name = playing ? 'Pause' : 'Play';
        this._prev.reactive = pick.proxy.CanGoPrevious !== false;
        this._next.reactive = pick.proxy.CanGoNext !== false;
    }

    // Out of the clock when playback starts; back in HIDE_AFTER_MS after it pauses or stops (paused,
    // it still shows the track until then, for a quick resume).
    _show(playing) {
        if (playing) {
            this._cancelHide();
            if (this._shown)
                return;
            this._shown = true;
            this.container.visible = true;
            this.emit('place');
            popOut(this.container, clockActor(), {pivot: [0, 0.5]});
        } else if (this._shown && !this._hideId) {
            // why: repeats only while its menu is open (nothing signals "closed and still paused");
            // its id stays set until it really ends, so playing again can cancel it.
            this._hideId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, HIDE_AFTER_MS, () => {
                if (this.menu.isOpen) // still in use: wait for the menu to close
                    return GLib.SOURCE_CONTINUE;
                this._hideId = 0;
                this._shown = false;
                retreat(this.container, clockActor(), {pivot: [0, 0.5], onDone: () => (this.container.visible = this._shown)});
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _cancelHide() {
        if (this._hideId)
            GLib.source_remove(this._hideId);
        this._hideId = 0;
    }

    // The keybinding: play or pause what's showing.
    playPause() {
        this._player?.PlayPauseRemote();
    }

    destroy() {
        this._cancelHide();
        this._players.destroy();
        this._player = null;
        super.destroy();
    }
});

// The clock's bubble in the top bar: where the pill comes from and goes back to.
function clockActor() {
    return Main.panel.statusArea.dateMenu ?? Main.panel;
}

export class NowPlayingPill {
    constructor() {
        this._button = new NowPlaying();
        // Above the bar, beside the clock; hidden with the bar in fullscreen. A panel button is the
        // child of its container: the container is what goes on the stage, placed and animated.
        Main.layoutManager.addTopChrome(this._button.container, {trackFullscreen: true});
        Main.panel.menuManager.addMenu(this._button.menu);
        const place = () => {
            const clock = clockActor();
            const [cx, cy] = clock.get_transformed_position();
            const [cw, ch] = clock.get_transformed_size();
            const [, h] = this._button.container.get_preferred_height(-1);
            this._button.container.set_position(Math.round(cx + cw + GAP), Math.round(cy + (ch - h) / 2));
        };
        this._button.connectObject('place', place, this);
        clockActor().connectObject('notify::allocation', place, this);
        // Not on the lock screen.
        Main.sessionMode.connectObject('updated', () => {
            this._button.container.opacity = Main.sessionMode.isLocked ? 0 : 255;
        }, this);
    }

    playPause() {
        this._button?.playPause();
    }

    get button() {
        return this._button;
    }

    destroy() {
        clockActor().disconnectObject(this);
        Main.sessionMode.disconnectObject(this);
        if (this._button) {
            Main.panel.menuManager.removeMenu(this._button.menu);
            // The button itself: its destroy() stops the players and the timer, and destroys its
            // container (destroying only the container skipped that, leaking at every lock).
            this._button.destroy();
        }
        this._button = null;
    }
}
