// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/sources.js: system readings from /proc and sysfs. No GNOME Shell imports, so the
// parsers can be unit-tested with plain gjs (tests/js/).
//
// Two kinds of reads: readTextSync for the per-tick files (/proc, coretemp, runtime_status), which
// the kernel generates in memory in microseconds; and async reads for the popup-only sensors, some
// of which (dell_smm, dell_ddv) go through firmware calls and can block for milliseconds. Async
// reads hop through GLib's thread pool several times each, which costs wakeups on every tick.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

Gio._promisify(Gio.File.prototype, 'load_contents_async');
Gio._promisify(Gio.File.prototype, 'enumerate_children_async');
Gio._promisify(Gio.FileEnumerator.prototype, 'next_files_async');
Gio._promisify(Gio.File.prototype, 'query_filesystem_info_async');

const decoder = new TextDecoder();

// ---- parsers (pure) --------------------------------------------------------------------------

// /proc/stat → {total: {idle, busy}, cores: [{idle, busy}, ...]} in jiffies.
export function parseProcStat(text) {
    const result = {total: null, cores: []};
    for (const line of text.split('\n')) {
        const m = line.match(/^cpu(\d*)\s+(.*)$/);
        if (!m)
            continue;
        const v = m[2].trim().split(/\s+/).map(Number);
        // user nice system idle iowait irq softirq steal (guest columns are already in user/nice)
        const idle = v[3] + (v[4] || 0);
        const busy = v[0] + v[1] + v[2] + (v[5] || 0) + (v[6] || 0) + (v[7] || 0);
        if (m[1] === '')
            result.total = {idle, busy};
        else
            result.cores[Number(m[1])] = {idle, busy};
    }
    return result;
}

// Percent busy between two {idle, busy} samples; null when there is no usable interval.
export function cpuPercent(prev, cur) {
    if (!prev || !cur)
        return null;
    const busy = cur.busy - prev.busy;
    const total = busy + (cur.idle - prev.idle);
    return total > 0 ? Math.max(0, Math.min(100, (100 * busy) / total)) : null;
}

// /proc/meminfo → {totalKb, availableKb, usedPercent, cachedKb, swapTotalKb, swapUsedKb}.
export function parseMeminfo(text) {
    const kb = key => {
        const m = text.match(new RegExp(`^${key}:\\s+(\\d+)`, 'm'));
        return m ? Number(m[1]) : null;
    };
    const totalKb = kb('MemTotal');
    const availableKb = kb('MemAvailable');
    if (!totalKb || availableKb === null)
        return null;
    const swapTotalKb = kb('SwapTotal') ?? 0;
    return {
        totalKb, availableKb, usedPercent: (100 * (totalKb - availableKb)) / totalKb,
        cachedKb: (kb('Cached') ?? 0) + (kb('Buffers') ?? 0),
        swapTotalKb, swapUsedKb: swapTotalKb - (kb('SwapFree') ?? swapTotalKb),
    };
}

// /proc/loadavg → {one, five, fifteen, running, total}.
export function parseLoadavg(text) {
    const m = (text ?? '').match(/^([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\/(\d+)/);
    if (!m)
        return null;
    return {one: Number(m[1]), five: Number(m[2]), fifteen: Number(m[3]), running: Number(m[4]), total: Number(m[5])};
}

// /proc/uptime → seconds since boot.
export function parseUptime(text) {
    const n = Number((text ?? '').split(/\s+/)[0]);
    return Number.isFinite(n) && text ? n : null;
}

// /proc/net/dev → {rx, tx} bytes over every interface except loopback.
export function parseNetDev(text) {
    let rx = 0, tx = 0, any = false;
    for (const line of (text ?? '').split('\n')) {
        const m = line.match(/^\s*([^:\s]+):\s*(.*)$/);
        if (!m || m[1] === 'lo')
            continue;
        const v = m[2].trim().split(/\s+/).map(Number);
        rx += v[0];
        tx += v[8];
        any = true;
    }
    return any ? {rx, tx} : null;
}

// Whole disks only (partitions would count every byte twice).
const DISK = /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$/;

// /proc/diskstats → {read, write} bytes over whole disks (sectors are always 512 bytes here).
export function parseDiskstats(text) {
    let read = 0, write = 0, any = false;
    for (const line of (text ?? '').split('\n')) {
        const v = line.trim().split(/\s+/);
        if (v.length < 10 || !DISK.test(v[2]))
            continue;
        read += Number(v[5]) * 512;
        write += Number(v[9]) * 512;
        any = true;
    }
    return any ? {read, write} : null;
}

// Per second between two counters taken `seconds` apart; null without a usable interval.
export function rate(prev, cur, seconds) {
    if (prev === null || prev === undefined || cur === null || cur === undefined || !(seconds > 0) || cur < prev)
        return null;
    return (cur - prev) / seconds;
}

// Core clocks in kHz (scaling_cur_freq) → {avgMhz, maxMhz}, or null when there are none.
export function cpuFrequency(khz) {
    const v = khz.filter(Number.isFinite);
    if (v.length === 0)
        return null;
    return {avgMhz: v.reduce((a, b) => a + b, 0) / v.length / 1000, maxMhz: Math.max(...v) / 1000};
}

// Picks the CPU package temperature (°C) from [{chip, label, celsius}].
const PACKAGE_SENSORS = [
    s => s.chip === 'coretemp' && /^Package id/.test(s.label),
    s => s.chip === 'k10temp' && /^(Tctl|Tdie)$/.test(s.label),
    s => s.chip === 'zenpower' && /^(Tctl|Tdie)$/.test(s.label),
    s => s.chip === 'cpu_thermal',
    s => s.chip === 'acpitz',
];

// The package sensor itself ({chip, label, celsius}), or null.
export function packageSensor(sensors) {
    for (const match of PACKAGE_SENSORS) {
        const s = sensors.find(match);
        if (s)
            return s;
    }
    return null;
}

export function packageTemperature(sensors) {
    return packageSensor(sensors)?.celsius ?? null;
}

// Battery draw in watts from a power_supply's values (µW, or µA × µV). Positive while discharging.
export function batteryWatts({power_now: power, current_now: current, voltage_now: voltage} = {}) {
    if (Number.isFinite(power))
        return power / 1e6;
    if (Number.isFinite(current) && Number.isFinite(voltage))
        return (current * voltage) / 1e12;
    return null;
}

// ---- I/O ----------------------------------------------------------------------------------------

// Synchronous read for kernel-generated files that never block (procfs, coretemp, power state).
export function readTextSync(path) {
    try {
        const [, bytes] = GLib.file_get_contents(path);
        return decoder.decode(bytes).trim();
    } catch {
        return null;
    }
}

export async function readText(path, cancellable = null) {
    try {
        const [bytes] = await Gio.File.new_for_path(path).load_contents_async(cancellable);
        return decoder.decode(bytes).trim();
    } catch (e) {
        if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw e;
        return null;
    }
}

async function readNumber(path, cancellable) {
    const text = await readText(path, cancellable);
    const n = text === null ? NaN : Number(text);
    return Number.isFinite(n) ? n : null;
}

export async function listDir(path, cancellable = null) {
    try {
        const e = await Gio.File.new_for_path(path).enumerate_children_async(
            'standard::name', Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT, cancellable);
        const names = [];
        for (;;) {
            const infos = await e.next_files_async(64, GLib.PRIORITY_DEFAULT, cancellable);
            if (infos.length === 0)
                break;
            names.push(...infos.map(i => i.get_name()));
        }
        return names.sort();
    } catch (err) {
        if (err.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw err;
        return [];
    }
}

// hwmon chips by name → directory, found once at startup ({coretemp: '/sys/class/hwmon/hwmon8'}).
export async function findHwmon(root = '/sys/class/hwmon', cancellable = null) {
    const chips = {};
    for (const entry of await listDir(root, cancellable)) {
        const name = await readText(`${root}/${entry}/name`, cancellable);
        if (name && !(name in chips))
            chips[name] = `${root}/${entry}`;
    }
    return chips;
}

// All tempN / fanN / inN inputs of one chip →
// {temps: [{chip, label, celsius}], fans: [{chip, label, rpm}], volts: [{chip, label, volts}]}.
export async function readChip(chip, dir, cancellable = null) {
    const temps = [], fans = [], volts = [];
    for (const f of await listDir(dir, cancellable)) {
        const m = f.match(/^(temp|fan|in)(\d+)_input$/);
        if (!m)
            continue;
        const value = await readNumber(`${dir}/${f}`, cancellable);
        if (value === null)
            continue;
        const label = (await readText(`${dir}/${m[1]}${m[2]}_label`, cancellable)) || `${m[1]}${m[2]}`;
        if (m[1] === 'temp')
            temps.push({chip, label, celsius: value / 1000});
        else if (m[1] === 'fan')
            fans.push({chip, label, rpm: value});
        else
            volts.push({chip, label, volts: value / 1000});
    }
    return {temps, fans, volts};
}

// The filesystem holding `path`: {size, free} in bytes, or null.
export async function readFilesystem(path = '/', cancellable = null) {
    try {
        const info = await Gio.File.new_for_path(path).query_filesystem_info_async(
            'filesystem::size,filesystem::free', GLib.PRIORITY_DEFAULT, cancellable);
        return {
            size: info.get_attribute_uint64('filesystem::size'),
            free: info.get_attribute_uint64('filesystem::free'),
        };
    } catch (e) {
        if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw e;
        return null;
    }
}

// The first battery: {path, status, watts, percent}, or null when there is none.
export async function readBattery(root = '/sys/class/power_supply', cancellable = null) {
    for (const entry of await listDir(root, cancellable)) {
        const dir = `${root}/${entry}`;
        if ((await readText(`${dir}/type`, cancellable)) !== 'Battery')
            continue;
        const values = {};
        for (const k of ['power_now', 'current_now', 'voltage_now', 'capacity'])
            values[k] = await readNumber(`${dir}/${k}`, cancellable);
        return {
            path: dir,
            status: await readText(`${dir}/status`, cancellable),
            watts: batteryWatts(values),
            percent: values.capacity,
        };
    }
    return null;
}

// Integrated GPU clock: {actMhz, maxMhz} from i915 (gt_*) or xe (tile0/gt0/freq0/*), else null.
export async function readIgpuFrequency(drmRoot = '/sys/class/drm', cancellable = null) {
    for (const card of await listDir(drmRoot, cancellable)) {
        if (!/^card\d+$/.test(card))
            continue;
        const base = `${drmRoot}/${card}`;
        let act = await readNumber(`${base}/gt_act_freq_mhz`, cancellable);
        let max = await readNumber(`${base}/gt_max_freq_mhz`, cancellable);
        if (act === null) {
            act = await readNumber(`${base}/device/tile0/gt0/freq0/act_freq`, cancellable);
            max = await readNumber(`${base}/device/tile0/gt0/freq0/max_freq`, cancellable);
        }
        if (act !== null)
            return {actMhz: act, maxMhz: max};
    }
    return null;
}
