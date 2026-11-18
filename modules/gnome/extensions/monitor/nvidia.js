// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/nvidia.js: NVIDIA dGPU state without ever waking it (logic ported from nvidia-power).
//
// The runtime power state comes from sysfs. Only while the card is already awake do we look for the
// processes holding it (/proc, never the driver) and, if some exist, ask nvidia-smi for usage, backing
// off while it sits idle so the driver can put it to sleep.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {listDir, readText, readTextSync} from './sources.js';

// Every nvidia-smi call counts as GPU activity and restarts the driver's sleep timer. While the
// apps holding the card leave it idle, ask this rarely so it gets the gap it needs to suspend.
const IDLE_QUERY_SECONDS = 30;
const IDLE_SAMPLES_BEFORE_BACKOFF = 3;

const QUERY_FIELDS = 'name,utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu';

// Processes that keep the card open for the whole session without using it: they never count as
// "using the GPU", and their presence alone is no reason to query it.
const ALWAYS_OPEN = new Set(['gnome-shell', 'Xwayland', 'nvidia-smi']);

// Every GL, Vulkan or CUDA context on NVIDIA's driver opens /dev/nvidia<N>; its DRM render node is not
// enough, since Chromium/Electron GPU processes open every render node just to enumerate GPUs.
const DEVICE_NODES = ['/dev/nvidia[0-9]*'];

// The first NVIDIA display controller's sysfs path, or null.
export async function findNvidiaGpu(root = '/sys/bus/pci/devices') {
    for (const name of await listDir(root)) {
        const path = `${root}/${name}`;
        if ((await readText(`${path}/vendor`)) !== '0x10de')
            continue;
        if ((await readText(`${path}/class`))?.startsWith('0x03'))
            return path;
    }
    return null;
}

// "app-flatpak-com.lunarclient.LunarClient-2060268014.scope" →
//     {kind: 'flatpak', id: 'com.lunarclient.LunarClient', name: 'LunarClient', scope}
// kind is null for scopes that are not a whole app GNOME launched (terminal tabs and the like).
export function appFromCgroup(cgroup) {
    const scope = cgroup.split('/').pop() ?? '';
    const app = scope.match(/^app-(flatpak-|gnome-)?(.+?)(?:-[0-9a-f]+)?\.scope$/);
    const snap = scope.match(/^snap\.([^.]+)\./);
    if (!app && !snap)
        return null;
    if (snap)
        return {kind: 'snap', id: snap[1], name: snap[1], scope};
    // terminals run each tab in "app-ghostty-surface-transient-8839.scope"
    const id = app[2].replace(/\\x2d/g, '-').replace(/-(?:surface-)?transient$/, '');
    const kind = {'flatpak-': 'flatpak', 'gnome-': 'desktop'}[app[1]] ?? null;
    return {kind, id, name: id.split('.').pop(), scope};
}

function describe(comm, app) {
    if (!app || app.name.toLowerCase().includes(comm.toLowerCase()))
        return app?.name ?? comm;
    return `${comm} (${app.name})`;
}

function number(text) {
    const value = parseFloat(text);
    return Number.isFinite(value) ? value : null;
}

export function run(argv, cancellable = null) {
    return new Promise((resolve, reject) => {
        const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        proc.communicate_utf8_async(null, cancellable, (p, result) => {
            try {
                const [, stdout] = p.communicate_utf8_finish(result);
                resolve(p.get_successful() ? stdout : null);
            } catch (e) {
                reject(e);
            }
        });
    });
}

// Quitting stops a whole app GNOME launched (systemd sends SIGTERM to every process in its scope,
// then SIGKILL after a timeout). Anything else, such as a portal or a process in a terminal tab,
// shares its cgroup with things that must keep running, so only its own processes are signalled.
export async function quit(user) {
    if (user.app?.kind)
        await run(['systemctl', '--user', 'stop', user.app.scope]);
    else
        await run(['kill', '-TERM', ...user.pids]);
}

export class Nvidia {
    constructor(gpuPath, scriptPath) {
        this._path = gpuPath;
        this._script = scriptPath;
        this.awake = false;
        this.since = null;
        this.stats = null;
        this.users = [];
        this._idleSamples = 0;
        this._lastQuery = 0;
    }

    get backingOff() {
        return this.users.length > 0 && this._idleSamples >= IDLE_SAMPLES_BEFORE_BACKOFF;
    }

    get idleQuerySeconds() {
        return IDLE_QUERY_SECONDS;
    }

    // One poll. Reads sysfs only, unless the card is already awake.
    async update(cancellable) {
        // sysfs reports the runtime power state without waking the device
        const awake = readTextSync(`${this._path}/power/runtime_status`) === 'active';
        if (awake !== this.awake) {
            this.awake = awake;
            this.since = awake ? GLib.DateTime.new_now_local().format('%H:%M:%S') : null;
            this.stats = null;
            this._idleSamples = 0;
            this._lastQuery = 0;
        }
        if (!awake) {
            this.users = [];
            return;
        }
        this.users = await this._findUsers(cancellable);
        if (this.users.length > 0 && this._shouldQuery())
            await this._query(cancellable);
        else if (this.users.length === 0)
            this.stats = null;
    }

    async _findUsers(cancellable) {
        const out = await run(['/bin/sh', this._script, ...DEVICE_NODES], cancellable);
        const users = new Map();
        for (const line of (out ?? '').split('\n')) {
            const [pid, comm, cgroup = ''] = line.split('\t');
            if (!pid || !comm || ALWAYS_OPEN.has(comm))
                continue;
            const app = appFromCgroup(cgroup);
            const name = describe(comm, app);
            const user = users.get(name) ?? {key: name, name, pids: [], app};
            user.pids.push(pid);
            users.set(name, user);
        }
        return [...users.values()];
    }

    _shouldQuery() {
        const now = GLib.get_monotonic_time() / 1e6;
        const interval = this._idleSamples >= IDLE_SAMPLES_BEFORE_BACKOFF ? IDLE_QUERY_SECONDS : 0;
        return now - this._lastQuery >= interval;
    }

    async _query(cancellable) {
        this._lastQuery = GLib.get_monotonic_time() / 1e6;
        const out = await run(['nvidia-smi', `--query-gpu=${QUERY_FIELDS}`, '--format=csv,noheader,nounits'], cancellable);
        const fields = out?.split('\n')[0]?.split(',').map(f => f.trim());
        if (!fields || fields.length < 6) {
            this.stats = null;
            return;
        }
        const [name, load, used, total, watts, temp] = fields;
        this.stats = {name, load: number(load), used: number(used), total: number(total), watts: number(watts), temp: number(temp)};
        this._idleSamples = this.stats.load ? 0 : this._idleSamples + 1;
    }
}
