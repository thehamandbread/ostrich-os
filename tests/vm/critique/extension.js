// SPDX-License-Identifier: GPL-2.0-or-later
// Critique (test VM only, never shipped): press Super+Alt+C, box what's wrong, type a note.
//
// The screen freezes as it was (a screenshot shown full-screen, so open menus and hover states
// stay). Drag a box, or click a part to pick it (it's outlined and named: "Dock › Firefox"). Type
// the note, pick Bug / Looks wrong / Idea; Enter saves, Shift+Enter is a new line, Esc cancels.
// More boxes can go in the same note.
//
// Each note is a folder in ~/critiques/<time>-<slug>/: screen.png (with the boxes drawn), one
// crop per box, note.json (the text, what was boxed and which extension owns it, that extension's
// settings, versions) and errors.txt (the last two minutes of warnings). tests/vm/critique.sh pulls
// them to the host. Nothing runs until the key is pressed.

import Cairo from 'cairo';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Config from 'resource:///org/gnome/shell/misc/config.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {boxFromDrag, cropRect, describe, slug} from './pick.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot', 'screenshot_finish');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async', 'communicate_utf8_finish');

const KINDS = [['bug', 'Bug'], ['looks-wrong', 'Looks wrong'], ['idea', 'Idea']];
const OURS = '@ubuntu-ostrich';

async function run(argv) {
    try {
        const p = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE);
        const [out] = await p.communicate_utf8_async(null, null);
        return (out ?? '').trim();
    } catch (e) {
        return `(${argv[0]} failed: ${e.message})`;
    }
}

function writeText(path, text) {
    Gio.File.new_for_path(path).replace_contents(new TextEncoder().encode(text), null, false,
        Gio.FileCreateFlags.REPLACE_DESTINATION, null);
}

// The panel status-area role an actor is the container of, if any.
function roleOf(actor) {
    for (const [role, indicator] of Object.entries(Main.panel.statusArea)) {
        if (indicator === actor || indicator?.container === actor)
            return role;
    }
    return null;
}

// The picked actor and its parents, as plain facts for pick.js.
function chainOf(actor) {
    const chain = [];
    for (let a = actor; a && chain.length < 25; a = a.get_parent()) {
        chain.push({
            type: a.constructor?.name ?? 'actor',
            name: a.name || undefined,
            styleClass: a.style_class || undefined,
            role: roleOf(a) ?? undefined,
            // A QuickToggle logs a warning when its .label is read: read its title.
            text: a instanceof St.Label || a instanceof St.Button ? (a.text ?? ('title' in a ? a.title : a.label) ?? undefined) : undefined,
            app: a.app?.get_name?.() ?? undefined,
        });
    }
    return chain;
}

// The top normal window under a point, as facts for pick.js.
function windowAt(x, y) {
    const tracker = Shell.WindowTracker.get_default();
    const actors = global.get_window_actors().filter(a => !a.meta_window.minimized && a.visible).reverse();
    for (const a of actors) {
        const w = a.meta_window;
        const r = w.get_frame_rect();
        if (w.get_window_type() === Meta.WindowType.DESKTOP || x < r.x || y < r.y || x >= r.x + r.width || y >= r.y + r.height)
            continue;
        const app = tracker.get_window_app(w);
        return {
            appId: w.get_gtk_application_id?.() || app?.get_id() || w.get_wm_class() || null,
            appName: app?.get_name() ?? null,
            title: w.get_title() ?? '',
            frame: {x: r.x, y: r.y, width: r.width, height: r.height},
        };
    }
    return null;
}

// Every key of one of our extensions' settings, as plain values.
function extensionSettings(uuid) {
    try {
        const dir = GLib.build_filenamev([GLib.get_user_data_dir(), 'gnome-shell', 'extensions', uuid]);
        const meta = JSON.parse(new TextDecoder().decode(Gio.File.new_for_path(`${dir}/metadata.json`).load_contents(null)[1]));
        const source = Gio.SettingsSchemaSource.new_from_directory(`${dir}/schemas`, Gio.SettingsSchemaSource.get_default(), false);
        const schema = source.lookup(meta['settings-schema'], false);
        if (!schema)
            return null;
        const s = new Gio.Settings({settings_schema: schema});
        return Object.fromEntries(schema.list_keys().map(k => [k, s.get_value(k).recursiveUnpack()]));
    } catch (e) {
        return {error: e.message};
    }
}

function gnomeSettings(ids) {
    const out = {};
    for (const [id, keys] of ids) {
        try {
            const s = new Gio.Settings({schema_id: id});
            out[id] = Object.fromEntries(keys.map(k => [k, s.get_value(k).recursiveUnpack()]));
        } catch {
            // not installed
        }
    }
    return out;
}

export default class CritiqueExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._ui = null;
        Main.wm.addKeybinding('start-critique', this._settings, Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.ALL, () => {
                this._start().catch(e => console.error(`critique: ${e.message}`));
            });
    }

    disable() {
        Main.wm.removeKeybinding('start-critique');
        this._close();
        this._settings = null;
    }

    // ---- capture ----

    async _start() {
        if (this._ui || this._starting)
            return;
        this._starting = true; // the screenshot is awaited; a second press must not open a second overlay
        try {
            await this._capture();
        } finally {
            this._starting = false;
        }
    }

    async _capture() {
        // What's under the pointer now, before anything changes (menus may close later).
        const [px, py] = global.get_pointer();
        const pointerActor = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, px, py);
        const pointer = {x: px, y: py, chain: chainOf(pointerActor), window: windowAt(px, py)};
        const tmp = GLib.dir_make_tmp('critique-XXXXXX');
        const shotPath = `${tmp}/screen.png`;
        const stream = Gio.File.new_for_path(shotPath).replace(null, false, Gio.FileCreateFlags.NONE, null);
        await new Shell.Screenshot().screenshot(false, stream);
        stream.close(null);
        this._open({tmp, shotPath, pointer, time: GLib.DateTime.new_now_local()});
    }

    _open(capture) {
        const [w, h] = [global.stage.width, global.stage.height];
        const overlay = new St.Widget({
            reactive: true, can_focus: true, x: 0, y: 0, width: w, height: h,
            style: `background-image: url("file://${capture.shotPath}"); background-size: ${w}px ${h}px;`,
            layout_manager: new Clutter.FixedLayout(),
        });
        Main.uiGroup.add_child(overlay);
        const grab = Main.pushModal(overlay, {actionMode: Shell.ActionMode.POPUP});
        const ui = {...capture, overlay, grab, boxes: [], kind: 'looks-wrong', drag: null};
        this._ui = ui;

        ui.band = new St.Widget({style_class: 'ost-critique-band', visible: false});
        overlay.add_child(ui.band);
        ui.card = this._card(ui);
        overlay.add_child(ui.card);
        ui.card.set_position(Math.round((w - 560) / 2), h - 300);

        overlay.connect('button-press-event', (_a, ev) => {
            if (ui.card.contains(global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, ...ev.get_coords())))
                return Clutter.EVENT_PROPAGATE;
            const [x, y] = ev.get_coords();
            ui.drag = [x, y];
            return Clutter.EVENT_STOP;
        });
        overlay.connect('motion-event', (_a, ev) => {
            if (!ui.drag)
                return Clutter.EVENT_PROPAGATE;
            const [x, y] = ev.get_coords();
            const b = boxFromDrag(ui.drag[0], ui.drag[1], x, y);
            ui.band.set_position(b.x, b.y);
            ui.band.set_size(Math.max(1, b.width), Math.max(1, b.height));
            ui.band.visible = !b.click;
            return Clutter.EVENT_STOP;
        });
        overlay.connect('button-release-event', (_a, ev) => {
            if (!ui.drag)
                return Clutter.EVENT_PROPAGATE;
            const [x, y] = ev.get_coords();
            const b = boxFromDrag(ui.drag[0], ui.drag[1], x, y);
            ui.drag = null;
            ui.band.visible = false;
            this._addBox(ui, b);
            return Clutter.EVENT_STOP;
        });
        overlay.connect('key-press-event', (_a, ev) => {
            if (ev.get_key_symbol() === Clutter.KEY_Escape) {
                this._close();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        global.stage.set_key_focus(ui.entry.clutter_text);
    }

    // A box (or a click on a part): pick what's under it from the live stage, outline and name it.
    _addBox(ui, b) {
        const cx = b.click ? b.x : b.x + b.width / 2;
        const cy = b.click ? b.y : b.y + b.height / 2;
        // A click picks one point; a box picks its middle and four points inside it, so a box
        // over several icons names all of them.
        const points = b.click ? [[cx, cy]] : [[cx, cy],
            ...[[0.2, 0.3], [0.8, 0.3], [0.2, 0.7], [0.8, 0.7]].map(([fx, fy]) => [b.x + b.width * fx, b.y + b.height * fy])];
        ui.overlay.hide();
        const picks = points.map(([x, y]) => {
            const a = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y);
            return {actor: a, chain: chainOf(a), win: windowAt(x, y)};
        });
        ui.overlay.show();
        const {actor, chain, win} = picks[0];
        const named = picks.map(p => describe(p.chain, p.win));
        const label = [...new Set(named.map(n => n.label))].join(' + ');
        const owner = named[0].owner ?? named.find(n => n.owner)?.owner ?? null;
        // A click outlines what it hit: a shell part by its own extent, a window as a whole.
        let box = {x: Math.round(b.x), y: Math.round(b.y), width: Math.round(b.width), height: Math.round(b.height)};
        if (b.click && win && chain.length <= 2) {
            box = {...win.frame};
        } else if (b.click && actor && actor !== global.stage) {
            const [ax, ay] = actor.get_transformed_position();
            const [aw, ah] = actor.get_transformed_size();
            box = {x: Math.round(ax), y: Math.round(ay), width: Math.round(aw), height: Math.round(ah)};
        }
        const outline = new St.Widget({style_class: 'ost-critique-box', x: box.x, y: box.y, width: Math.max(2, box.width), height: Math.max(2, box.height)});
        const tag = new St.Label({style_class: 'ost-critique-tag', text: `${ui.boxes.length + 1}  ${label}`, x: box.x, y: Math.max(0, box.y - 22)});
        ui.overlay.insert_child_below(outline, ui.card);
        ui.overlay.insert_child_below(tag, ui.card);
        ui.boxes.push({...box, label, owner, chain, also: picks.slice(1).map(p => p.chain[0]), window: win});
        ui.boxList.text = ui.boxes.map((x, i) => `${i + 1}. ${x.label}`).join('\n');
        global.stage.set_key_focus(ui.entry.clutter_text);
    }

    // ---- the note card ----

    _card(ui) {
        const card = new St.BoxLayout({style_class: 'ost-critique-card', vertical: true, reactive: true, width: 560});
        card.add_child(new St.Label({style_class: 'ost-critique-title', text: 'Drag a box around the problem (or click a part), then say what\'s wrong'}));
        ui.boxList = new St.Label({style_class: 'ost-critique-list', text: ''});
        card.add_child(ui.boxList);
        ui.entry = new St.Entry({style_class: 'ost-critique-entry', hint_text: 'What\'s wrong, or what would be better?', can_focus: true, x_expand: true});
        const text = ui.entry.clutter_text;
        text.single_line_mode = false;
        text.line_wrap = true;
        text.activatable = false;
        text.connect('key-press-event', (_t, ev) => {
            const sym = ev.get_key_symbol();
            const shift = (ev.get_state() & Clutter.ModifierType.SHIFT_MASK) !== 0;
            if ((sym === Clutter.KEY_Return || sym === Clutter.KEY_KP_Enter) && !shift) {
                this._save(ui).catch(e => console.error(`critique: save failed: ${e.message}`));
                return Clutter.EVENT_STOP;
            }
            if (sym === Clutter.KEY_Escape) {
                this._close();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        card.add_child(ui.entry);
        const row = new St.BoxLayout({style_class: 'ost-critique-row'});
        ui.kindButtons = KINDS.map(([kind, label]) => {
            const b = new St.Button({label, style_class: 'ost-critique-kind', toggle_mode: true, checked: kind === ui.kind, can_focus: true});
            b.connect('clicked', () => {
                ui.kind = kind;
                ui.kindButtons.forEach(x => {
                    x.checked = x === b;
                });
                global.stage.set_key_focus(ui.entry.clutter_text);
            });
            row.add_child(b);
            return b;
        });
        row.add_child(new St.Widget({x_expand: true}));
        const cancel = new St.Button({label: 'Cancel (Esc)', style_class: 'ost-critique-button'});
        cancel.connect('clicked', () => this._close());
        const save = new St.Button({label: 'Save (Enter)', style_class: 'ost-critique-button ost-critique-save'});
        save.connect('clicked', () => this._save(ui).catch(e => console.error(`critique: save failed: ${e.message}`)));
        row.add_child(cancel);
        row.add_child(save);
        card.add_child(row);
        return card;
    }

    // ---- saving ----

    async _save(ui) {
        const text = ui.entry.get_text().trim();
        if (!text && ui.boxes.length === 0) {
            this._close();
            return;
        }
        const stamp = ui.time.format('%Y%m%d-%H%M%S');
        const id = `${stamp}-${slug(text)}`;
        const dir = GLib.build_filenamev([GLib.get_home_dir(), 'critiques', id]);
        GLib.mkdir_with_parents(dir, 0o755);
        const screen = {width: global.stage.width, height: global.stage.height, scale: St.ThemeContext.get_for_stage(global.stage).scale_factor};

        // The screenshot with the boxes drawn on it, and a crop of each box.
        const src = Cairo.ImageSurface.createFromPNG(ui.shotPath);
        const marked = new Cairo.ImageSurface(Cairo.Format.ARGB32, src.getWidth(), src.getHeight());
        const cr = new Cairo.Context(marked);
        cr.setSourceSurface(src, 0, 0);
        cr.paint();
        cr.setSourceRGBA(1, 0.15, 0.3, 1);
        cr.setLineWidth(3);
        ui.boxes.forEach(b => {
            cr.rectangle(b.x, b.y, Math.max(2, b.width), Math.max(2, b.height));
            cr.stroke();
        });
        marked.writeToPNG(`${dir}/screen.png`);
        cr.$dispose();
        ui.boxes.forEach((b, i) => {
            const c = cropRect(b, 40, screen);
            const crop = new Cairo.ImageSurface(Cairo.Format.ARGB32, c.width, c.height);
            const cc = new Cairo.Context(crop);
            cc.setSourceSurface(marked, -c.x, -c.y);
            cc.paint();
            crop.writeToPNG(`${dir}/crop-${i + 1}.png`);
            cc.$dispose();
        });

        // What it was about.
        const owners = [...new Set([...ui.boxes.map(b => b.owner), describe(ui.pointer.chain, ui.pointer.window).owner]
            .filter(o => o?.endsWith(OURS)))];
        const shell = new Gio.Settings({schema_id: 'org.gnome.shell'});
        const srcDir = GLib.build_filenamev([GLib.get_user_data_dir(), 'ubuntu-ostrich', 'src']);
        const note = {
            id,
            time: ui.time.format_iso8601(),
            kind: ui.kind,
            text,
            boxes: ui.boxes.map(({chain, ...b}) => ({...b, chain})),
            pointer: {...ui.pointer, ...describe(ui.pointer.chain, ui.pointer.window)},
            settings: Object.fromEntries(owners.map(o => [o, extensionSettings(o)])),
            gnome: gnomeSettings([
                ['org.gnome.desktop.interface', ['color-scheme', 'accent-color', 'enable-animations', 'text-scaling-factor']],
                ['org.gnome.desktop.wm.preferences', ['workspace-names', 'num-workspaces']],
                ['org.gnome.mutter', ['dynamic-workspaces']],
            ]),
            versions: {
                ostrich: await run(['git', '-C', srcDir, 'describe', '--always', '--dirty']),
                version: await run(['cat', `${srcDir}/VERSION`]),
                shell: Config.PACKAGE_VERSION,
                powerProfile: await run(['powerprofilesctl', 'get']),
                enabledExtensions: shell.get_strv('enabled-extensions'),
            },
            screen,
        };
        writeText(`${dir}/note.json`, `${JSON.stringify(note, null, 2)}\n`);
        // The last two minutes, kept to what matters: GNOME Shell, Ubuntu Ostrich, and crashes.
        const relevant = /gnome-shell|ostrich|JS ERROR|JS WARNING|segfault|dumped core|Gjs-CRITICAL|WebKit/i;
        const keep = text => text.split('\n').filter(l => relevant.test(l)).join('\n') || '(nothing)';
        const errors = [
            '== GNOME Shell and Ubuntu Ostrich (user journal, last 2 minutes, warnings and worse)',
            keep(await run(['journalctl', '--user', '-b', '--since', '-2min', '-p', 'warning', '-o', 'short-iso', '--no-pager'])),
            '',
            '== crashes (system journal, last 2 minutes)',
            keep(await run(['journalctl', '-b', '--since', '-2min', '-p', 'err', '-o', 'short-iso', '--no-pager'])),
        ].join('\n');
        writeText(`${dir}/errors.txt`, `${errors}\n`);

        this._close();
        const count = Gio.File.new_for_path(GLib.build_filenamev([GLib.get_home_dir(), 'critiques']))
            .enumerate_children('standard::name', 0, null);
        let n = 0;
        while (count.next_file(null))
            n++;
        Main.notify('Critique saved', `${n} note${n === 1 ? '' : 's'} so far. Say /critiques in Claude Code when you're done.`);
    }

    _close() {
        const ui = this._ui;
        if (!ui)
            return;
        this._ui = null;
        Main.popModal(ui.grab);
        ui.overlay.destroy();
        try {
            Gio.File.new_for_path(ui.shotPath).delete(null);
            Gio.File.new_for_path(ui.tmp).delete(null);
        } catch {
            // already gone
        }
    }
}
