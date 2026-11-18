// SPDX-License-Identifier: GPL-2.0-or-later
// Monitor: readings in the top bar, and a popup of sections (Processor, Memory, Temperature, Fans,
// Voltage, System, Network, Storage, Battery, Graphics) with a row per value. Any row's star pins
// it to the top bar (vitals.js).
//
// Cost rules: every read is /proc or sysfs; nothing runs while the screen is locked;
// intervals follow AC / battery / power saver; with the popup shut, only what the pins show is read;
// the NVIDIA card is only ever asked for usage while it is already awake (see nvidia.js).

import Atk from 'gi://Atk';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Graphene from 'gi://Graphene';
import St from 'gi://St';

import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {ensureActorVisibleInScrollView} from 'resource:///org/gnome/shell/misc/animationUtils.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PowerAwareTimer, profilesProxy} from './_lib/timers.js';
import {Signals} from './_lib/signals.js';
import {HoverLabel} from './_lib/label.js';
import * as KeepOff from './keepoff.js';
import {lowBatteryRule, saverValue, SAVER_DESKTOP, UPOWER_DISCHARGING} from './battery.js';
import {Nvidia, findNvidiaGpu, quit, appFromCgroup} from './nvidia.js';
import {memoryPressure, memoryWarningRule, biggestApp, warningText, blames} from './memory.js';
import {PopOut} from './_lib/alert.js';
import {animate, stop, QUICK, STANDARD} from './_lib/motion.js';
import {
    parseProcStat, cpuPercent, parseMeminfo, packageTemperature, packageSensor,
    parseLoadavg, parseUptime, parseNetDev, parseDiskstats, rate, cpuFrequency,
    readText, readTextSync, listDir, findHwmon, readChip, readBattery, readIgpuFrequency, readFilesystem,
} from './sources.js';
import {SECTIONS, buildSections, panelItems, togglePin, needed, rowName} from './vitals.js';

const HELPER = '/usr/libexec/ubuntu-ostrich/system-helper';
// Opened by the popup's monitor button: the first that is installed.
const MONITOR_APPS = ['net.nokyan.Resources.desktop', 'org.gnome.SystemMonitor.desktop', 'gnome-system-monitor.desktop'];
// Said under every alert that asks before ending an app (_lib/alert.js `warn`).
const UNSAVED_WARNING = 'Unsaved work is lost.';

// One row of an open section, in em of the menu's text size (about 24 px by default): the height cap
// counts rows of this size. Same as .ost-vital-row in the stylesheet, whose min-height is the floor that
// stops St squeezing the rows to fit the cap instead of scrolling them.
const SECTION_ROW_EM = 1.62;

// Power modes are switched with GNOME's Power Mode tile (the popup has no power row of its own). The names are for the low-battery alert.
const PROFILE_NAMES = {'power-saver': 'Power Saver', 'balanced': 'Balanced', 'performance': 'Performance'};

// A text line in the popup. Not a menu item: an insensitive item would be greyed out by the
// theme, and fixed colours break on light themes, so this is a plain label in the theme's text colour.
class InfoLine {
    constructor(menu, text = '', extraClass = null) {
        this.label = new St.Label({text, style_class: 'ost-monitor-line'});
        if (extraClass)
            this.label.add_style_class_name(extraClass);
        this.label.clutter_text.line_wrap = false;
        (menu.box ?? menu.actor).add_child(this.label);
    }

    get visible() {
        return this.label.visible;
    }

    set visible(v) {
        this.label.visible = v;
    }
}

const infoItem = (menu, text, extraClass) => new InfoLine(menu, text, extraClass);

function setText(label, text) {
    if (label.text !== text)
        label.text = text;
}

function libexec(cmd) {
    const ours = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'libexec', 'ubuntu-ostrich', cmd]);
    return GLib.file_test(ours, GLib.FileTest.IS_EXECUTABLE) ? ours : GLib.find_program_in_path(cmd) ?? ours;
}

// One value in a section: its name, the value on the right, and a star that pins it to the top bar.
// Activating it (click, Return) pins or unpins without closing the menu. To a screen reader it is a
// toggle button named by its value ("Processor Usage 12%"), checked while pinned.
const VitalRow = GObject.registerClass(
class MonitorVitalRow extends PopupMenu.PopupBaseMenuItem {
    _init(id, onToggle, scroll) {
        super._init({style_class: 'ost-vital-row'});
        // Rows of a capped section scroll with the keyboard: GNOME's menu doesn't bring a focused row
        // of a submenu into view.
        this.connect('key-focus-in', () => {
            if (scroll?.vscrollbar_policy === St.PolicyType.AUTOMATIC)
                ensureActorVisibleInScrollView(scroll, this);
        });
        this.accessible_role = Atk.Role.TOGGLE_BUTTON;
        this.id = id;
        this._onToggle = onToggle;
        this.label = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this.value = new St.Label({style_class: 'ost-vital-value', y_align: Clutter.ActorAlign.CENTER});
        this.star = new St.Icon({style_class: 'popup-menu-icon ost-vital-star', icon_name: 'non-starred-symbolic'});
        this.add_child(this.label);
        this.add_child(this.value);
        this.add_child(this.star);
        this._pinned = null;
    }

    update(section, label, value, pinned) {
        setText(this.label, label);
        setText(this.value, value);
        const name = rowName(section, label, value);
        if (this.accessible_name !== name)
            this.accessible_name = name;
        if (pinned === this._pinned)
            return;
        this._pinned = pinned;
        this.star.icon_name = pinned ? 'starred-symbolic' : 'non-starred-symbolic';
        if (pinned)
            this.add_accessible_state(Atk.StateType.CHECKED);
        else
            this.remove_accessible_state(Atk.StateType.CHECKED);
    }

    activate() {
        this._onToggle(this.id);
    }
});

const Indicator = GObject.registerClass(
class MonitorIndicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, 'Monitor');
        this._ext = extension;
        this._settings = extension.getSettings();
        this._signals = new Signals();
        this._labels = new HoverLabel(); // names for the footer's icon-only buttons
        this._cancellable = new Gio.Cancellable();
        this._busy = false;
        this._prevStat = null;
        this._packageSensor = null; // {path} of the package temperature input, found once
        this._chips = {};
        this._nvidia = null;

        this._samples = {}; // previous counters for rates: {net: {rx, tx, t}, disk: {read, write, t}}
        this._fs = null;
        this._fsAt = 0;
        this._fanChips = null;

        // ---- top bar: the pinned values, each an icon and its value ----
        // One row (a panel button lays out only its first child): the readings, and the icon that stands
        // in their place in power saver (see _pausedTick).
        const row = new St.BoxLayout();
        this.add_child(row);
        this._box = new St.BoxLayout({style_class: 'ost-monitor-panel', pivot_point: new Graphene.Point({x: 0, y: 0.5})});
        row.add_child(this._box);
        this._saverIcon = new St.Icon({
            gicon: this._gicon('theme:power-profile-power-saver-symbolic'), style_class: 'system-status-icon', visible: false,
        });
        row.add_child(this._saverIcon);
        this._panelItems = new Map(); // id → {box, icon, value, shown}
        this._panelKeys = null;

        // ---- popup ----
        // One width whatever the readings (CSS .ost-monitor-menu): without it the menu followed its widest
        // line and slid sideways as a rate changed.
        this.menu.box.add_style_class_name('ost-monitor-menu');
        // The values pinned to the top bar come first, then the sections.
        this._pinnedSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._pinnedSection);
        this._pinnedRows = new Map(); // id → VitalRow; made once, then shown or hidden, never destroyed on the way
        this._pinnedSeparator = new PopupMenu.PopupSeparatorMenuItem();
        this._pinnedSection.addMenuItem(this._pinnedSeparator);
        this._vitals = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._vitals);
        this._sections = new Map(); // id → {item, summary, rows: Map, keys}
        for (const [id, title, icon] of SECTIONS) {
            const item = new PopupMenu.PopupSubMenuMenuItem(title, true);
            item.add_style_class_name('ost-vital-section');
            item.icon.gicon = this._gicon(icon);
            const summary = new St.Label({style_class: 'ost-vital-summary', y_align: Clutter.ActorAlign.CENTER});
            item.insert_child_below(summary, item.get_last_child()); // before the arrow
            item.visible = false;
            this._vitals.addMenuItem(item);
            // GNOME's menus are accordions: a section that opens tells the top-level menu (_setOpenedSubMenu),
            // which closes the one open before. Clearing what it remembers (this runs after the item's own
            // handler) lets sections open side by side.
            // shortcut: pokes the top-level menu's private _openedSubMenu (GNOME 50 popupMenu.js); if GNOME
            // renames it the sections go back to one at a time, so look there on a new GNOME.
            this._signals.connect(item.menu, 'open-state-changed', (_m, open) => {
                if (open)
                    this.menu._openedSubMenu = null;
            });
            const sec = {item, summary, rows: new Map(), keys: null};
            this._sections.set(id, sec);
            // GNOME shows a submenu's scrollbar only when the whole menu has a max-height, and resets it
            // on every open; ours is capped per section, so put it back.
            this._signals.connect(item.menu.actor, 'notify::vscrollbar-policy', () => this._capSection(sec));
        }
        this._signals.connect(this._settings, 'changed::section-rows', () => {
            for (const sec of this._sections.values())
                this._capSection(sec);
        });

        this._nvidiaSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._nvidiaSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        // Shown in power saver, where nothing is read (see _pausedTick).
        this._pausedNote = new St.Label({
            text: 'Paused in power saver · last reading', // wraps inside the fixed menu width
            style_class: 'ost-monitor-line ost-monitor-note', visible: false,
        });
        this._pausedNote.clutter_text.line_wrap = true;
        const noteSection = new PopupMenu.PopupMenuSection();
        noteSection.actor.add_child(this._pausedNote);
        this.menu.addMenuItem(noteSection);
        this._buildFooter();

        this._signals.connect(this.menu, 'open-state-changed', (_m, open) => {
            if (!open)
                return;
            // Fill the details straight away, and again a moment later: rates need two samples.
            this._tick();
            this._soon ??= GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
                this._soon = null;
                this._tick();
                return GLib.SOURCE_REMOVE;
            });
        });
        for (const key of ['panel-items', 'hide-zeros'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._tick());

        this._init2().catch(e => console.warn(`monitor: setup failed: ${e.message}`));
    }

    _gicon(name) {
        if (name.startsWith('theme:'))
            return new Gio.ThemedIcon({name: name.slice(6)});
        return Gio.FileIcon.new(Gio.File.new_for_path(GLib.build_filenamev([this._ext.path, 'icons', `${name}-symbolic.svg`])));
    }

    // The buttons along the bottom, right-aligned, in a plain box: GNOME greys a menu item that can't be activated.
    _buildFooter() {
        const item = new St.BoxLayout({style_class: 'ost-vital-footer', x_expand: true});
        item.add_child(new St.Widget({x_expand: true}));
        const button = (icon, name, action, label) => {
            const b = new St.Button({
                style_class: 'button ost-vital-button', can_focus: true, accessible_name: name,
                child: new St.Icon({icon_name: icon, style_class: 'popup-menu-icon'}),
            });
            b.connect('clicked', action);
            this._labels.attach(b, label);
            item.add_child(b);
            return b;
        };
        // While paused (power saver) a refresh reads once: say so where the button is named.
        this._refreshButton = button('view-refresh-symbolic', 'Refresh now', () => this._tick(true),
            () => (this._pausedNote.visible ? 'Refresh now: reads once while paused' : 'Refresh now'));
        this._monitorApp = MONITOR_APPS.map(id => Shell.AppSystem.get_default().lookup_app(id)).find(a => a) ?? null;
        if (this._monitorApp) {
            button('utilities-system-monitor-symbolic', `Open ${this._monitorApp.get_name()}`, () => {
                this.menu.close();
                this._monitorApp.activate();
            });
        }
        button('preferences-system-symbolic', 'Monitor settings', () => {
            this.menu.close();
            // Ostrich Settings when it is installed; the extension's own preferences window when it is not
            // (the extension also installs alone from extensions.gnome.org).
            const setup = libexec('ostrich-setup');
            if (!GLib.file_test(setup, GLib.FileTest.IS_EXECUTABLE)) {
                this._ext.openPreferences();
                return;
            }
            try {
                Gio.Subprocess.new([setup, '--step', 'top-bar'], Gio.SubprocessFlags.NONE);
            } catch (e) {
                console.warn(`monitor: could not open Ostrich Settings: ${e.message}`);
                this._ext.openPreferences();
            }
        });
        const section = new PopupMenu.PopupMenuSection();
        section.actor.add_child(item);
        this.menu.addMenuItem(section);
    }

    _pins() {
        return this._settings.get_strv('panel-items');
    }

    _togglePin(id) {
        this._settings.set_strv('panel-items', togglePin(this._pins(), id));
    }

    // Async setup: sensor discovery, NVIDIA, power profiles, then the timer.
    async _init2() {
        this._chips = await findHwmon('/sys/class/hwmon', this._cancellable);
        for (const [chip, dir] of Object.entries(this._chips)) {
            const {temps} = await readChip(chip, dir, this._cancellable);
            if (packageTemperature(temps) !== null) {
                // Remember which input file is the package sensor, so each tick reads one file.
                for (const name of await listDir(dir, this._cancellable)) {
                    const m = name.match(/^temp(\d+)_label$/);
                    if (!m)
                        continue;
                    const label = await readText(`${dir}/${name}`, this._cancellable);
                    if (packageTemperature([{chip, label, celsius: 0}]) !== null) {
                        this._packageSensor = `${dir}/temp${m[1]}_input`;
                        break;
                    }
                }
                if (!this._packageSensor && ['cpu_thermal', 'acpitz'].includes(chip))
                    this._packageSensor = `${dir}/temp1_input`;
                if (this._packageSensor)
                    break;
            }
        }

        const gpu = await findNvidiaGpu();
        if (!this._settings)
            return; // switched off while this was starting (destroy() ran)
        if (gpu) {
            this._nvidia = new Nvidia(gpu, GLib.build_filenamev([this._ext.path, 'gpu-users.sh']));
            this._buildNvidiaMenu();
        }

        this._initProfiles().catch(e => console.warn(`monitor: power profile setup failed: ${e.message}`));

        this._timer = new PowerAwareTimer({
            ac: this._settings.get_uint('interval-ac'),
            battery: this._settings.get_uint('interval-battery'),
            saver: this._settings.get_uint('interval-saver'),
        }, () => this._tick());
        await this._timer.start();
    }

    // ---- polling ----

    // `force`: read even in power saver (the Refresh button, the user's own ask).
    async _tick(force = false) {
        if (this._busy)
            return;
        this._busy = true;
        try {
            if (this._paused() && !force)
                await this._pausedTick();
            else
                await this._update();
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                console.warn(`monitor: update failed: ${e.message}`);
        } finally {
            this._busy = false;
        }
    }

    // ---- power saver: no readings ----
    // The top bar's readings fold away to the left and a power-saver icon takes their place, so the
    // popup can still be opened; the popup says
    // why. Only memory is still checked (one in-memory file every interval-saver seconds), because
    // running out of it freezes the machine, which costs more battery than the check.

    _paused() {
        return this._lastProfile === 'power-saver';
    }

    async _pausedTick() {
        // Started in power saver: nothing was ever read, so read once for the popup's last reading.
        if (this._panelKeys === undefined)
            await this._update();
        if (this._settings.get_boolean('memory-warning'))
            this._checkMemory(parseMeminfo(readTextSync('/proc/meminfo') ?? ''));
        if (!this._paused()) // switched out of saver while the first read ran: _resume has run
            return;
        this._pausedNote.visible = true;
        if (this._folded)
            return;
        this._folded = true;
        // Fade and squeeze toward the left edge (scale and opacity only: no relayout while it moves),
        // then the icon fades in.
        // shortcut: the width changes at once at the end; on the default left side nothing sits to the
        // monitor's right so it isn't seen, but with panel-box center/right its neighbours jump once.
        // Animate the width if anyone moves it there.
        animate(this._box, {opacity: 0, scale_x: 0.3}, {
            duration: STANDARD, mode: Clutter.AnimationMode.EASE_IN_QUAD, onDone: () => {
                this._box.hide();
                this._saverIcon.set({opacity: 0, visible: true});
                animate(this._saverIcon, {opacity: 255}, {duration: QUICK});
            },
        });
    }

    _resume() {
        for (const p of this._panelItems.values())
            p.shown = null; // the next reading is shown whatever its step
        this._pausedNote.visible = false;
        if (this._folded) {
            this._folded = false;
            stop(this._saverIcon);
            this._saverIcon.hide();
            this._box.set({opacity: 0, scale_x: 0.3, visible: true});
            animate(this._box, {opacity: 255, scale_x: 1}, {duration: STANDARD});
        }
        this._tick();
    }

    // Memory and swap nearly full: one notice naming the app holding the most, before it grinds.
    _checkMemory(mem) {
        const rule = memoryWarningRule(memoryPressure(mem), this._memoryWarned ?? false);
        this._memoryWarned = rule.warned;
        if (!rule.warn)
            return;
        const app = this._biggestApp();
        const buttons = [];
        if (blames(app, mem.totalKb) && app.scopes.length > 0) {
            buttons.push({
                label: `End ${app.name}`,
                confirm: `End ${app.name}?`,
                warn: UNSAVED_WARNING,
                action: () => this._endApp(app),
            });
        }
        if (this._monitorApp) {
            buttons.push({
                label: `Open ${this._monitorApp.get_name()}`,
                action: () => this._monitorApp.activate(),
            });
        }
        this._popOut({
            title: 'Memory is nearly full',
            body: warningText(app, mem.totalKb),
            gicon: app?.gicon ?? this._gicon('memory'),
            buttons,
        });
    }

    // One pop-out at a time from the monitor; a new one replaces the one showing.
    _popOut(spec) {
        this._alert?.destroy();
        const alert = new PopOut(this, spec);
        this._alert = alert;
        alert.card.connect('destroy', () => {
            if (this._alert === alert) // an older card shrinking away mustn't forget this one
                this._alert = null;
        });
        alert.show();
    }

    async _endApp(app) {
        try {
            for (const scope of app.scopes)
                await quit({app: {kind: 'desktop', scope}, pids: []});
        } catch (e) {
            Main.notifyError('Monitor', `Could not end ${app.name}: ${e.message}`);
        }
    }

    // Read only when warning: each process's resident memory, added up per app (its systemd scope).
    _biggestApp() {
        const apps = Shell.AppSystem.get_default();
        const processes = [];
        const icons = new Map(); // app name -> its icon, for the pop-out
        let dir;
        try {
            dir = GLib.Dir.open('/proc', 0);
        } catch {
            return null;
        }
        const pageKb = 4;
        for (let pid; (pid = dir.read_name()) !== null;) {
            if (!/^\d+$/.test(pid))
                continue;
            const app = appFromCgroup(readTextSync(`/proc/${pid}/cgroup`)?.trim() ?? '');
            const pages = Number((readTextSync(`/proc/${pid}/statm`) ?? '').split(' ')[1]);
            if (app && pages > 0) {
                const found = apps.lookup_app(`${app.id}.desktop`);
                const name = found?.get_name() ?? app.name;
                if (found)
                    icons.set(name, found.get_icon());
                processes.push([name, pages * pageKb, app.scope]);
            }
        }
        dir.close();
        const best = biggestApp(processes);
        if (best)
            best.gicon = icons.get(best.name) ?? null;
        return best;
    }

    async _update() {
        const c = this._cancellable;
        const detail = this.menu.isOpen;
        const pins = this._pins();
        const need = detail ? null : needed(pins);
        const want = what => need === null || need.has(what);
        const now = GLib.get_monotonic_time() / 1e6;
        const r = {};

        // Per-tick files are read synchronously: they're generated in memory and never block,
        // while async reads would cost several thread-pool wakeups each (see sources.js).
        if (want('stat') || want('freq')) {
            const stat = parseProcStat(readTextSync('/proc/stat') ?? '');
            const prev = this._prevStat;
            this._prevStat = stat;
            r.cpu = {
                usage: cpuPercent(prev?.total, stat.total),
                cores: detail ? stat.cores.map((core, i) => cpuPercent(prev?.cores[i], core)) : [],
            };
            if (want('freq')) {
                r.cpu.freq = cpuFrequency(stat.cores.map((_, i) =>
                    Number(readTextSync(`/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq`) ?? NaN)));
            }
        }
        if (want('load'))
            r.load = parseLoadavg(readTextSync('/proc/loadavg'));
        if (want('uptime'))
            r.uptime = parseUptime(readTextSync('/proc/uptime'));
        const memoryWarning = this._settings.get_boolean('memory-warning');
        if (want('mem') || memoryWarning)
            r.mem = parseMeminfo(readTextSync('/proc/meminfo') ?? '');
        if (want('net')) {
            const n = parseNetDev(readTextSync('/proc/net/dev'));
            if (n) {
                const p = this._samples.net;
                r.net = {...n, down: rate(p?.rx, n.rx, now - p?.t), up: rate(p?.tx, n.tx, now - p?.t)};
                this._samples.net = {...n, t: now};
            }
        }
        if (want('diskstats')) {
            const d = parseDiskstats(readTextSync('/proc/diskstats'));
            if (d) {
                const p = this._samples.disk;
                r.disk = {read: rate(p?.read, d.read, now - p?.t), write: rate(p?.write, d.write, now - p?.t)};
                this._samples.disk = {...d, t: now};
            }
        }
        if (want('fs')) {
            // Free space moves slowly: once a minute is plenty.
            if (!this._fs || now - this._fsAt > 60) {
                this._fs = await readFilesystem('/', c);
                this._fsAt = now;
            }
            r.fs = this._fs;
        }

        let pkg = null;
        if (this._packageSensor && want('package')) {
            const t = Number(readTextSync(this._packageSensor));
            pkg = Number.isFinite(t) ? t / 1000 : null;
        }
        if (want('chips')) {
            const temps = [], fans = [], volts = [];
            for (const [chip, dir] of Object.entries(this._chips)) {
                const x = await readChip(chip, dir, c);
                temps.push(...x.temps);
                fans.push(...x.fans);
                volts.push(...x.volts);
            }
            const p = packageSensor(temps);
            r.temps = temps.map(t => (t === p ? {...t, package: true} : t));
            r.fans = fans;
            r.volts = volts;
        } else if (pkg !== null) {
            r.temps = [{chip: 'coretemp', label: 'Package', celsius: pkg, package: true}];
        }

        if (this._nvidia && want('nvidia')) {
            await this._nvidia.update(c);
            r.gpu = {awake: this._nvidia.awake, stats: this._nvidia.stats, name: this._nvidia.stats?.name};
            this._alertNvidia();
        }
        if (want('igpu'))
            r.igpu = await readIgpuFrequency('/sys/class/drm', c);
        if (want('battery')) {
            r.battery = await readBattery('/sys/class/power_supply', c);
            if (r.battery && this._battery) {
                const key = r.battery.status === 'Charging' ? 'TimeToFull' : 'TimeToEmpty';
                r.battery.timeLeft = this._battery.get_cached_property(key)?.unpack() ?? 0;
            }
        }

        if (memoryWarning)
            this._checkMemory(r.mem);
        const sections = buildSections(r, {hideZeros: this._settings.get_boolean('hide-zeros')});
        this._renderPanel(panelItems(pins, sections));
        if (!detail)
            return;
        this._renderPinned(sections, pins);
        this._renderSections(sections, new Set(pins));
        if (this._nvidia)
            this._renderNvidiaMenu();
        const s = this._timer?.state;
        // How often it refreshes, for the screen reader (the line that said it on screen was cut).
        this._refreshButton.accessible_name = s
            ? `Refresh now (it refreshes every ${s.interval} s${s.saver ? ' in power saver' : s.onBattery ? ' on battery' : ''})`
            : 'Refresh now';
    }

    // Panel readouts only change when the value moves by at least its row's `step`: every text
    // change redraws the top bar, and at idle CPU flickers between neighbouring values (1% and 2%).
    _renderPanel(items) {
        const keys = items.map(i => i.id).join('\n');
        if (keys !== this._panelKeys) {
            this._panelKeys = keys;
            this._box.destroy_all_children();
            this._panelItems.clear();
            for (const it of items) {
                const box = new St.BoxLayout({y_align: Clutter.ActorAlign.CENTER, style_class: 'ost-monitor-item'});
                const icon = new St.Icon({gicon: this._gicon(it.icon), style_class: 'system-status-icon ost-monitor-icon'});
                const value = new St.Label({style_class: 'ost-monitor-value', y_align: Clutter.ActorAlign.CENTER});
                box.add_child(icon);
                box.add_child(value);
                this._box.add_child(box);
                this._panelItems.set(it.id, {box, value, shown: null});
            }
            // Nothing pinned: an icon alone, so the popup can still be opened.
            if (items.length === 0)
                this._box.add_child(new St.Icon({gicon: this._gicon('system'), style_class: 'system-status-icon'}));
        }
        for (const it of items) {
            const p = this._panelItems.get(it.id);
            if (it.raw !== null && typeof p.shown === 'number' && Math.abs(it.raw - p.shown) < it.step)
                continue;
            p.shown = it.raw;
            setText(p.value, it.id === 'gpu.state' ? this._gpuPanelText() : it.value);
        }
    }

    _gpuPanelText() {
        const nv = this._nvidia;
        const s = nv?.stats;
        if (!nv?.awake)
            return 'off';
        return s ? `${s.load ?? '?'}% · ${s.watts !== null ? Math.round(s.watts) : '?'} W` : 'on';
    }

    // An open section shows `section-rows` rows, then scrolls. The height is in em, so it
    // follows the text size; the scrollbar is only on when the rows don't fit.
    _capSection(sec) {
        const scroll = sec.item.menu.actor;
        const cap = this._settings.get_uint('section-rows');
        scroll.style = `max-height: ${cap * SECTION_ROW_EM}em;`;
        const policy = sec.rows.size > cap ? St.PolicyType.AUTOMATIC : St.PolicyType.NEVER;
        if (scroll.vscrollbar_policy !== policy)
            scroll.vscrollbar_policy = policy;
    }

    // The pinned values again at the top of the popup, in pin order, each with its star (unpin in place).
    // A row is made the first time its value is read and after that only shown or hidden: rows destroyed
    // while one had keyboard focus or the pointer (an idle 0% reading drops out with hide-zeros) made GNOME
    // touch a disposed object.
    _renderPinned(sections, pins) {
        const byId = new Map();
        for (const model of sections)
            for (const x of model.rows)
                byId.set(x.id, {model, x});
        let at = 0;
        let any = false;
        for (const id of pins) {
            const found = byId.get(id);
            let row = this._pinnedRows.get(id);
            if (!found && !row)
                continue;
            if (!row) {
                row = new VitalRow(id, i => this._togglePin(i), null);
                this._pinnedSection.addMenuItem(row);
                this._pinnedRows.set(id, row);
            }
            row.visible = !!found;
            if (found) {
                any = true;
                row.update(found.model.title, found.x.label, found.x.value, true);
                setText(row.label, `${found.model.title} ${found.x.label}`); // the section's name is not above it here
            }
            this._pinnedSection.moveMenuItem(row, at++);
        }
        for (const [id, row] of this._pinnedRows) {
            if (!pins.includes(id))
                row.visible = false; // unpinned
        }
        this._pinnedSection.moveMenuItem(this._pinnedSeparator, this._pinnedRows.size);
        this._pinnedSeparator.visible = any;
    }

    // Each section's rows are rebuilt only when its set of rows changes (a sensor appears, the GPU
    // wakes), so an open section stays open and keyboard focus stays put between updates.
    _renderSections(sections, pinned) {
        const shown = new Set(sections.map(x => x.id));
        for (const [id, sec] of this._sections)
            sec.item.visible = shown.has(id);
        for (const model of sections) {
            const sec = this._sections.get(model.id);
            setText(sec.summary, model.summary);
            const keys = model.rows.map(x => x.id).join('\n');
            if (keys !== sec.keys) {
                sec.keys = keys;
                sec.item.menu.removeAll();
                sec.rows.clear();
                for (const x of model.rows) {
                    const row = new VitalRow(x.id, id => this._togglePin(id), sec.item.menu.actor);
                    sec.item.menu.addMenuItem(row);
                    sec.rows.set(x.id, row);
                }
                this._capSection(sec);
            }
            for (const x of model.rows)
                sec.rows.get(x.id).update(model.title, x.label, x.value, pinned.has(x.id));
        }
    }

    // ---- NVIDIA (ported from nvidia-power) ----

    _buildNvidiaMenu() {
        const m = this._nvidiaSection;
        m.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._nvUsersHeading = infoItem(m, 'Apps on the NVIDIA GPU (click one to stop it)', 'ost-monitor-heading');
        this._nvUsers = new PopupMenu.PopupMenuSection();
        m.addMenuItem(this._nvUsers);
        this._nvNote = infoItem(m, '', 'ost-monitor-note');
        this._nvKeptOff = new PopupMenu.PopupSubMenuMenuItem('');
        m.addMenuItem(this._nvKeptOff);
        this._nvUserKeys = null;
        this._nvUserItems = new Map();
        this._renderKeptOff();
    }

    _renderNvidiaMenu() {
        const nv = this._nvidia;
        this._nvUsersHeading.visible = nv.awake;
        this._renderUsers(nv.awake ? nv.users : null);
        let note = '';
        if (!nv.awake)
            note = `NVIDIA GPU asleep, using no power. Usage is only read while an app uses it`;
        else if (nv.since)
            note = `On since ${nv.since}`;
        if (nv.awake && nv.backingOff)
            note = `Idle: checking every ${nv.idleQuerySeconds} s so it can sleep`;
        setText(this._nvNote.label, note);
        this._nvNote.visible = note !== '';
    }

    // Rebuilt only when the set of apps changes, so a submenu you opened stays open between polls
    _renderUsers(users) {
        const keys = users === null ? '' : users.length === 0 ? '-' : users.map(u => u.key).join('\n');
        if (keys !== this._nvUserKeys) {
            this._nvUserKeys = keys;
            this._nvUsers.removeAll();
            this._nvUserItems.clear();
            if (users?.length === 0)
                infoItem(this._nvUsers, '  Nothing: it should sleep within seconds');
            for (const user of users ?? []) {
                const item = new PopupMenu.PopupSubMenuMenuItem('');
                item.menu.addAction('Quit', () => this._quit(this._nvUserItems.get(user.key).user));
                if (this._keepOffTarget(user))
                    item.menu.addAction('Keep off NVIDIA and quit', () => this._keepOff(this._nvUserItems.get(user.key).user));
                this._nvUsers.addMenuItem(item);
                this._nvUserItems.set(user.key, {item, user});
            }
        }
        for (const user of users ?? []) {
            const entry = this._nvUserItems.get(user.key);
            entry.user = user;
            setText(entry.item.label, user.pids.length > 1 ? `${user.name} ×${user.pids.length}` : user.name);
        }
    }

    // Flatpaks and apps GNOME launched from a .desktop file can be kept off; snaps, portals and
    // processes started from a terminal have no launcher to change
    _keepOffTarget(user) {
        const app = user.app;
        if (app?.kind === 'flatpak' || (app?.kind === 'desktop' && KeepOff.desktopFileFor(app.id)))
            return {kind: app.kind, id: app.id};
        return null;
    }

    // An app woke the NVIDIA GPU while on battery: a pop-out naming it, once per app per session.
    // On AC it costs no battery, so it isn't worth a word; quitting from the alert is a choice.
    _alertNvidia() {
        if (!this._timer?.state.onBattery)
            return;
        this._nvAlerted ??= new Set();
        const user = this._nvidia.users.find(u => u.app && !this._nvAlerted.has(u.key));
        if (!user)
            return;
        this._nvAlerted.add(user.key);
        const buttons = [{
            label: `Quit ${user.name}`, confirm: `Quit ${user.name}?`, warn: UNSAVED_WARNING,
            action: () => this._quit(user),
        }];
        if (this._keepOffTarget(user))
            buttons.push({label: 'Keep it off NVIDIA', action: () => this._keepOff(user)});
        this._popOut({
            title: `${user.name} woke the NVIDIA GPU`,
            body: 'It uses noticeably more battery while it is awake. Quit the app, or keep it on the built-in GPU from its next start.',
            gicon: this._gicon('theme:video-display-symbolic'),
            buttons,
        });
    }

    async _quit(user) {
        try {
            await quit(user);
        } catch (e) {
            Main.notifyError('Monitor', `Could not quit ${user.name}: ${e.message}`);
        }
    }

    async _keepOff(user) {
        try {
            await KeepOff.apply(this._keepOffTarget(user), user.app.name);
            await quit(user);
            Main.notify('Monitor', `${user.app.name} will use the Intel GPU from its next start. Undo it under “Kept off NVIDIA”.`);
        } catch (e) {
            Main.notifyError('Monitor', `Could not keep ${user.app.name} off NVIDIA: ${e.message}`);
        }
        this._renderKeptOff();
    }

    async _allow(id, name) {
        try {
            await KeepOff.undo(id);
            Main.notify('Monitor', `${name} can use the NVIDIA GPU again from its next start.`);
        } catch (e) {
            Main.notifyError('Monitor', `Could not undo it for ${name}: ${e.message}`);
        }
        this._renderKeptOff();
    }

    _renderKeptOff() {
        const entries = Object.entries(KeepOff.list());
        this._nvKeptOff.visible = entries.length > 0;
        this._nvKeptOff.label.text = `Kept off NVIDIA (${entries.length})`;
        this._nvKeptOff.menu.removeAll();
        for (const [id, {name}] of entries)
            this._nvKeptOff.menu.addAction(`Allow ${name} again`, () => this._allow(id, name));
    }

    // ---- power mode: power-profiles-daemon, plus our system helper's extra knobs (turbo, PCIe
    // ASPM, audio power save) applied on every change, whoever made it ----

    async _initProfiles() {
        const p = await profilesProxy(this._cancellable);
        // Switched off while the daemon was answering: destroy() ran and its objects are gone.
        if (!p || this._cancellable.is_cancelled())
            return;
        this._profiles = p;
        this._lastProfile = p.get_cached_property('ActiveProfile')?.unpack() ?? null;
        this._signals.connect(p, 'g-properties-changed', () => this._onProfileChanged());
        // A restart in the middle of power saver (or a crash) must not leave the desktop changed.
        this._applySaverDesktop(this._lastProfile === 'power-saver');
        this._initBattery();
    }

    _onProfileChanged() {
        const active = this._profiles?.get_cached_property('ActiveProfile')?.unpack() ?? null;
        if (active === this._lastProfile)
            return;
        const wasPaused = this._paused();
        this._lastProfile = active;
        if (this._paused())
            this._pausedTick(); // blanks the bar now, not at the next interval (even mid-read)
        else if (wasPaused)
            this._resume();
        this._applySaverDesktop(active === 'power-saver');
        this._checkBattery();
        // Installed only on machines that have the knobs; polkit lets the active user run it.
        if (!active || !GLib.file_test(HELPER, GLib.FileTest.IS_EXECUTABLE))
            return;
        try {
            const proc = Gio.Subprocess.new(['pkexec', HELPER, 'power', 'apply', active],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, null, (_p, res) => {
                try {
                    const [, , err] = proc.communicate_utf8_finish(res);
                    if (!proc.get_successful())
                        console.warn(`monitor: power apply ${active} failed: ${err}`);
                } catch (e) {
                    console.warn(`monitor: power apply ${active}: ${e.message}`);
                }
            });
        } catch (e) {
            console.warn(`monitor: could not run the system helper: ${e.message}`);
        }
    }

    // ---- power saver on the desktop: dim sooner; put back when it ends (animations stay: they're cheap) ----

    _applySaverDesktop(on) {
        const saved = this._settings.get_string('saved-desktop');
        const want = on && this._settings.get_boolean('saver-desktop');
        if (want && saved === '') {
            const before = {};
            for (const [schema, key, value] of SAVER_DESKTOP) {
                const gs = new Gio.Settings({schema_id: schema});
                const current = gs.get_value(key).recursiveUnpack();
                before[`${schema}|${key}`] = current;
                const v = saverValue(key, value, current);
                if (typeof v === 'boolean')
                    gs.set_boolean(key, v);
                else
                    gs.set_uint(key, v);
            }
            this._settings.set_string('saved-desktop', JSON.stringify(before));
        } else if (!want && saved !== '') {
            try {
                for (const [id, v] of Object.entries(JSON.parse(saved))) {
                    const [schema, key] = id.split('|');
                    const gs = new Gio.Settings({schema_id: schema});
                    if (typeof v === 'boolean')
                        gs.set_boolean(key, v);
                    else
                        gs.set_uint(key, v);
                }
            } catch (e) {
                console.warn(`monitor: could not put the desktop settings back: ${e.message}`);
            }
            this._settings.set_string('saved-desktop', '');
        }
    }

    // ---- low battery: power saver at or below the threshold, back when plugged in ----

    _initBattery() {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
            'org.freedesktop.UPower', '/org/freedesktop/UPower/devices/DisplayDevice',
            'org.freedesktop.UPower.Device', this._cancellable, (_o, res) => {
                try {
                    this._battery = Gio.DBusProxy.new_for_bus_finish(res);
                } catch {
                    return; // no UPower: no rule
                }
                if (!this._settings)
                    return;
                this._signals.connect(this._battery, 'g-properties-changed', () => this._checkBattery());
                this._signals.connect(this._settings, 'changed::auto-saver-percent', () => this._checkBattery());
                this._checkBattery();
            });
    }

    _checkBattery() {
        const b = this._battery;
        if (!b || !this._profiles || !this._settings || !b.get_cached_property('IsPresent')?.unpack())
            return;
        const decision = lowBatteryRule({
            onBattery: b.get_cached_property('State')?.unpack() === UPOWER_DISCHARGING,
            percent: b.get_cached_property('Percentage')?.unpack() ?? 100,
            profile: this._lastProfile ?? 'balanced',
            threshold: this._settings.get_uint('auto-saver-percent'),
            autoFrom: this._settings.get_string('auto-saver-from'),
        });
        if (!decision)
            return;
        this._settings.set_string('auto-saver-from', decision.autoFrom);
        if (decision.switchTo === 'power-saver') {
            this._setProfile('power-saver');
            const from = PROFILE_NAMES[decision.autoFrom] ?? decision.autoFrom;
            this._popOut({
                title: 'Power saver is on',
                body: `The battery is low, so the monitor switched to power saver. It goes back to ${from} when you plug in.`,
                gicon: Gio.ThemedIcon.new('power-profile-power-saver-symbolic'),
                buttons: [{label: `Keep ${from}`, action: () => this._setProfile(decision.autoFrom)}],
            });
        } else if (decision.switchTo) {
            this._setProfile(decision.switchTo);
        }
    }

    _setProfile(id) {
        const p = this._profiles;
        if (!p)
            return;
        p.call('org.freedesktop.DBus.Properties.Set',
            new GLib.Variant('(ssv)', [p.get_interface_name(), 'ActiveProfile', new GLib.Variant('s', id)]),
            Gio.DBusCallFlags.NONE, -1, this._cancellable, (_p, res) => {
                try {
                    p.call_finish(res);
                } catch (e) {
                    Main.notifyError('Monitor', `Could not switch power mode: ${e.message}`);
                }
            });
    }

    destroy() {
        this._alert?.destroy();
        if (this._soon)
            GLib.source_remove(this._soon);
        this._soon = null;
        this._timer?.stop();
        this._timer = null;
        // Switched off: leave the desktop as the user had it. Not when it's only the lock screen
        // (GNOME switches the monitor off while locked): power saver's shorter dimming must hold then.
        if (!Main.sessionMode.isLocked)
            this._applySaverDesktop(false);
        this._cancellable.cancel();
        this._labels.destroy();
        this._signals.disconnectAll();
        this._settings = null;
        super.destroy();
    }
});

export default class MonitorExtension extends Extension {
    enable() {
        this._indicator = new Indicator(this);
        const box = this.getSettings().get_string('panel-box');
        // Left box: after the workspace indicator/space bar, like Vitals' default position.
        Main.panel.addToStatusArea(this.uuid, this._indicator, box === 'left' ? 1 : 0, box);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
