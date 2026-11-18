// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/keepoff.js, ported from the nvidia-power extension.
// "Keep off NVIDIA": start an app with the NVIDIA driver hidden from it, so it renders on the
// Intel GPU and never wakes the card. Flatpaks get a `flatpak override`; apps with a launcher get
// `env …` put in front of every Exec= line of a user copy of their .desktop file.
import Gio from 'gi://Gio';
import GioUnix from 'gi://GioUnix';
import GLib from 'gi://GLib';

const STATE_FILE = GLib.build_filenamev([GLib.get_user_config_dir(), 'ubuntu-ostrich', 'keep-off.json']);
// Where the original nvidia-power extension kept this list; read once if ours doesn't exist yet.
const LEGACY_STATE_FILE = GLib.build_filenamev([GLib.get_user_config_dir(), 'nvidia-power', 'keep-off.json']);
const APPS_DIR = GLib.build_filenamev([GLib.get_user_data_dir(), 'applications']);
const MARKER = 'X-NvidiaPower-KeepOff=true';
// Marker names are kept from nvidia-power so launchers it already changed are still recognised.
// Written where we turned DBusActivatable off, since GNOME ignores Exec= for D-Bus activated apps
const DBUS_MARKER = 'X-NvidiaPower-DBusActivatable=true';

// GLX, EGL, Vulkan, VA-API and CUDA each load NVIDIA's driver on their own, so each is pointed away
function hideNvidia(eglVendorDir) {
    return {
        __GLX_VENDOR_LIBRARY_NAME: 'mesa',
        __EGL_VENDOR_LIBRARY_FILENAMES: `${eglVendorDir}/50_mesa.json`,
        VK_LOADER_DRIVERS_SELECT: '*intel*',
        LIBVA_DRIVER_NAME: 'iHD',
        CUDA_VISIBLE_DEVICES: '-1',
    };
}
const HOST_ENV = hideNvidia('/usr/share/glvnd/egl_vendor.d');
const FLATPAK_ENV = hideNvidia('/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d');
const EXEC_PREFIX = `env ${Object.entries(HOST_ENV).map(([k, v]) => `"${k}=${v}"`).join(' ')} `;

const decoder = new TextDecoder();

function readFile(path) {
    try {
        const [, bytes] = GLib.file_get_contents(path);
        return decoder.decode(bytes);
    } catch {
        return null;
    }
}

function writeFile(path, text) {
    GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o755);
    GLib.file_set_contents(path, text);
}

function spawn(argv) {
    return new Promise((resolve, reject) => {
        const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, null, (p, result) => {
            try {
                const [, , stderr] = p.communicate_utf8_finish(result);
                if (p.get_successful())
                    resolve();
                else
                    reject(new Error(stderr?.trim() || `${argv[0]} failed`));
            } catch (e) {
                reject(e);
            }
        });
    });
}

// {id: {kind: 'flatpak'|'desktop', name, createdFile?}}
export function list() {
    try {
        return JSON.parse(readFile(STATE_FILE) ?? readFile(LEGACY_STATE_FILE) ?? '{}');
    } catch {
        return {};
    }
}

function save(state) {
    writeFile(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);
}

// The launcher GNOME would use for this app id, if it has one
export function desktopFileFor(id) {
    return GioUnix.DesktopAppInfo.new(`${id}.desktop`)?.get_filename() ?? null;
}

export async function apply(target, name) {
    const state = list();
    if (target.kind === 'flatpak') {
        await spawn(['flatpak', 'override', '--user', ...Object.entries(FLATPAK_ENV).map(([k, v]) => `--env=${k}=${v}`), target.id]);
        state[target.id] = {kind: 'flatpak', name};
    } else {
        const source = desktopFileFor(target.id);
        const text = source ? readFile(source) : null;
        if (text === null)
            throw new Error(`No launcher found for ${target.id}`);
        const userCopy = GLib.build_filenamev([APPS_DIR, `${target.id}.desktop`]);
        const createdFile = !GLib.file_test(userCopy, GLib.FileTest.EXISTS);
        writeFile(userCopy, addPrefix(createdFile ? text : readFile(userCopy)));
        // A second apply finds our own copy: keep the first answer, so undo still removes it.
        state[target.id] = {kind: 'desktop', name, createdFile: state[target.id]?.createdFile ?? createdFile};
    }
    save(state);
}

export async function undo(id) {
    const state = list();
    const entry = state[id];
    if (!entry)
        return;
    if (entry.kind === 'flatpak') {
        await spawn(['flatpak', 'override', '--user', ...Object.keys(FLATPAK_ENV).map(k => `--unset-env=${k}`), id]);
    } else {
        const userCopy = GLib.build_filenamev([APPS_DIR, `${id}.desktop`]);
        if (entry.createdFile)
            GLib.unlink(userCopy);
        else if (GLib.file_test(userCopy, GLib.FileTest.EXISTS))
            writeFile(userCopy, removePrefix(readFile(userCopy)));
    }
    delete state[id];
    save(state);
}

export function addPrefix(text) {
    const lines = text.split('\n').map(line => {
        if (line.startsWith('Exec=') && !line.startsWith(`Exec=${EXEC_PREFIX}`))
            return `Exec=${EXEC_PREFIX}${line.slice('Exec='.length)}`;
        if (line.trim() === 'DBusActivatable=true')
            return `DBusActivatable=false\n${DBUS_MARKER}`;
        return line;
    });
    return withMarker(lines, true).join('\n');
}

export function removePrefix(text) {
    const lines = text.split('\n');
    const wasDbus = lines.some(line => line.trim() === DBUS_MARKER);
    const restored = lines
        .filter(line => line.trim() !== DBUS_MARKER)
        .map(line => {
            if (line.startsWith(`Exec=${EXEC_PREFIX}`))
                return `Exec=${line.slice(`Exec=${EXEC_PREFIX}`.length)}`;
            if (wasDbus && line.trim() === 'DBusActivatable=false')
                return 'DBusActivatable=true';
            return line;
        });
    return withMarker(restored, false).join('\n');
}

// The marker goes right under the [Desktop Entry] header, where it is visible to anyone reading it
function withMarker(lines, present) {
    const without = lines.filter(line => line.trim() !== MARKER);
    if (!present)
        return without;
    const header = without.findIndex(line => line.trim() === '[Desktop Entry]');
    without.splice(header + 1, 0, MARKER);
    return without;
}
