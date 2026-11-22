// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/today.js: the clock menu without its month grid. A card for this computer leads (the
// battery and time left, then the power mode, whether the NVIDIA GPU is asleep, the uptime, and a
// link to the monitor), and GNOME's world clocks and weather cards follow. Its Events card is
// EventsCard's, below, with or without Today. Media players stay where GNOME 50 puts them, at the
// top of the notification list.
//
// Read only while the menu is open, from cached D-Bus properties and sysfs; nothing polls.
// Everything is put back on disable.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {shellField} from './_lib/patches.js';
import {profilesProxy, proxy} from './_lib/timers.js';

const UPOWER_CHARGING = 1;
const UPOWER_DISCHARGING = 2;
const UPOWER_FULL = 4;
const MONITOR = 'monitor@ostrich-os'; // its indicator's role in the top bar
const PROFILES = {'performance': 'Performance', 'balanced': 'Balanced', 'power-saver': 'Power Saver'};

const decoder = new TextDecoder();

// Long lines wrap rather than end in "…" (the column has a fixed width; with large text they'd be cut).
function wrapping(label) {
    label.clutter_text.line_wrap = true;
    label.clutter_text.ellipsize = 0; // Pango.EllipsizeMode.NONE
    return label;
}

function read(path) {
    try {
        return decoder.decode(GLib.file_get_contents(path)[1]).trim();
    } catch {
        return null;
    }
}

export function duration(seconds) {
    const m = Math.round(seconds / 60);
    const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), min = m % 60;
    if (d > 0)
        return `${d} d ${h} h`;
    if (h > 0)
        return min > 0 ? `${h} h ${min} min` : `${h} h`;
    return `${min} min`;
}

// UPower DisplayDevice values → the battery line, or null without a battery. UPower reports 0
// time left while it is still estimating.
export function batteryLine({present, percent, state, toEmpty, toFull}) {
    if (!present)
        return null;
    const p = `${Math.round(percent)}%`;
    if (state === UPOWER_DISCHARGING)
        return toEmpty > 0 ? `Battery ${p} · ${duration(toEmpty)} left` : `Battery ${p} · estimating`;
    if (state === UPOWER_CHARGING)
        return toFull > 0 ? `Charging ${p} · full in ${duration(toFull)}` : `Charging ${p}`;
    if (state === UPOWER_FULL)
        return 'Battery full · plugged in';
    return `Battery ${p} · plugged in`;
}

// The card's text: a lead line (the battery, or the power mode on a machine without one) and the rows
// under it. battery: batteryLine()'s result; profile: the power-profiles-daemon name; nvidia:
// 'asleep', 'on' or null; uptime in seconds.
export function cardText({battery, profile, nvidia, uptime}) {
    const rows = [];
    if (profile)
        rows.push(`Power mode: ${PROFILES[profile] ?? profile}`);
    if (nvidia)
        rows.push(nvidia === 'asleep' ? 'NVIDIA GPU asleep' : 'NVIDIA GPU on');
    if (Number.isFinite(uptime) && uptime > 0)
        rows.push(`Running for ${duration(uptime)}`);
    const lead = battery ?? rows.shift() ?? null;
    return {lead, rows};
}

// The NVIDIA card's runtime power state from sysfs: 'asleep', 'on', or null when there is none.
function nvidiaState() {
    let dir;
    try {
        dir = Gio.File.new_for_path('/sys/bus/pci/devices').enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    } catch {
        return null;
    }
    for (let info; (info = dir.next_file(null));) {
        const base = `/sys/bus/pci/devices/${info.get_name()}`;
        if (read(`${base}/vendor`) !== '0x10de' || !/^0x03/.test(read(`${base}/class`) ?? ''))
            continue;
        dir.close(null);
        // As monitor/nvidia.js: only 'active' is awake, so the two never disagree.
        return read(`${base}/power/runtime_status`) === 'active' ? 'on' : 'asleep';
    }
    dir.close(null);
    return null;
}

export class Today {
    constructor(settings, launch) {
        this._settings = settings; // the tweaks settings (show-events)
        this._launch = launch; // (argv) => void
        this._menu = Main.panel.statusArea.dateMenu;
        this._cancellable = new Gio.Cancellable();
        this._proxies = {};
    }

    enable() {
        const m = this._menu;
        const calendar = shellField(m, '_calendar', 'tweaks');
        const displays = shellField(m, '_eventsItem', 'tweaks')?.get_parent();
        if (!calendar || !displays)
            return; // the clock menu has changed shape: left as it is
        m._calendar.hide();
        // Fixed widths that add up to the menu's: GNOME sizes the notification list in em, so it grew
        // with large text and pushed this column out of the menu. This column scrolls instead.
        this._column = m._calendar.get_parent();
        this._column.add_style_class_name('ost-today-column');
        // One size, whatever is in it: the menu no longer grows and shrinks with notifications and
        // players (the notification list scrolls inside it).
        this._menuBox = this._column.get_parent();
        this._menuBox?.add_style_class_name('ost-today-menu');

        // The card: its body opens the Power page; the link under it opens the monitor's popup.
        this._card = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, style_class: 'ost-today-card'});
        const body = new St.Button({
            style_class: 'ost-today-body',
            can_focus: true,
            x_expand: true,
            accessible_name: 'This computer: power settings',
        });
        const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        box.add_child(new St.Label({style_class: 'ost-today-title', text: 'This computer', x_align: Clutter.ActorAlign.START}));
        this._lead = wrapping(new St.Label({style_class: 'ost-today-lead', x_align: Clutter.ActorAlign.START}));
        box.add_child(this._lead);
        this._lines = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'ost-today-lines'});
        box.add_child(this._lines);
        body.child = box;
        body.connect('clicked', () => {
            m.menu.close();
            this._launch(['ostrich-setup', '--step', 'power']);
        });
        this._card.add_child(body);
        this._monitorLink = new St.Button({
            style_class: 'ost-today-link',
            label: 'System monitor ›',
            can_focus: true,
            x_align: Clutter.ActorAlign.START,
        });
        this._monitorLink.connect('clicked', () => {
            m.menu.close();
            Main.panel.statusArea[MONITOR]?.menu?.open();
        });
        this._card.add_child(this._monitorLink);
        // First in the column, above the world clocks and weather.
        displays.insert_child_at_index(this._card, 0);

        this._openId = m.menu.connect('open-state-changed', (_m, open) => {
            if (open)
                this._refresh();
        });
        // Either may be missing (no UPower, no power-profiles-daemon): that line is left out.
        profilesProxy(this._cancellable).then(p => p && (this._proxies.profiles = p));
        proxy('org.freedesktop.UPower', '/org/freedesktop/UPower/devices/DisplayDevice', 'org.freedesktop.UPower.Device',
            this._cancellable).then(p => p && (this._proxies.battery = p));
    }

    disable() {
        this._cancellable.cancel();
        if (this._openId)
            this._menu.menu.disconnect(this._openId);
        this._openId = 0;
        this._card?.destroy();
        this._card = this._lead = this._lines = this._monitorLink = null;
        this._column?.remove_style_class_name('ost-today-column');
        this._menuBox?.remove_style_class_name('ost-today-menu');
        this._menuBox = null;
        this._column = null;
        this._menu?._calendar?.show();
        this._proxies = {};
    }

    _text() {
        const b = this._proxies.battery;
        const get = (p, k) => p?.get_cached_property(k)?.unpack();
        const battery = b ? batteryLine({
            present: get(b, 'IsPresent'), percent: get(b, 'Percentage') ?? 0, state: get(b, 'State'),
            toEmpty: get(b, 'TimeToEmpty') ?? 0, toFull: get(b, 'TimeToFull') ?? 0,
        }) : null;
        return cardText({
            battery,
            profile: get(this._proxies.profiles, 'ActiveProfile'),
            nvidia: nvidiaState(),
            uptime: Number((read('/proc/uptime') ?? '').split(' ')[0]),
        });
    }

    _refresh() {
        if (!this._lines)
            return;
        const {lead, rows} = this._text();
        this._lead.text = lead ?? '';
        this._lead.visible = Boolean(lead);
        this._lines.destroy_all_children();
        for (const text of rows)
            this._lines.add_child(wrapping(new St.Label({text, style_class: 'ost-today-line', x_align: Clutter.ActorAlign.START})));
        this._monitorLink.visible = Boolean(Main.panel.statusArea[MONITOR]);
    }
}

// GNOME's calendar events card in the clock menu, with or without Today: hidden unless show-events
// is on (it mostly said "No Events"; note 20261101-224757 turned it off and it stayed).
export class EventsCard {
    constructor(settings) {
        this._settings = settings;
        this._item = shellField(Main.panel.statusArea.dateMenu, '_eventsItem', 'tweaks');
    }

    enable() {
        if (!this._item)
            return; // the clock menu has changed shape: left as it is
        this._changedId = this._settings.connect('changed::show-events', () => this._apply(true));
        // GNOME's events section shows itself again whenever it refreshes; hide it each time.
        this._visibleId = this._item.connect('notify::visible', () => this._apply());
        this._apply();
    }

    disable() {
        if (!this._item)
            return;
        this._settings.disconnect(this._changedId);
        this._item.disconnect(this._visibleId);
        this._item.show();
        this._item = null;
    }

    // Off: hidden, whenever GNOME shows it. Turned on: shown once, then GNOME decides as usual.
    _apply(keyChanged = false) {
        if (!this._settings.get_boolean('show-events'))
            this._item.visible &&= false;
        else if (keyChanged)
            this._item.show();
    }
}
