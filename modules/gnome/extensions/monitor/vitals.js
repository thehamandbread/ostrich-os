// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/vitals.js: what the popup and the top bar show, from one set of readings. No GNOME Shell
// imports, so it can be unit-tested with plain gjs (tests/js/).
//
// The popup is a list of sections (Processor, Memory, Temperature, ...), each a row per value. Any
// row can be pinned to the top bar; pins are row ids kept in the `panel-items` setting, in order.

// ---- formatting ---------------------------------------------------------------------------------

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];
// Rates use one letter ("985 K/s"): the popup keeps one width, so its longest reading has to be short.
const RATE_UNITS = ['B', 'K', 'M', 'G', 'T'];

// Steps up at 1000 (dividing by 1024), so a value is never more than three digits ("1.0 K", not "1010 B"):
// the popup's width holds the longest reading, and a fourth digit would cut it.
const scaled = (v, units) => {
    let i = 0;
    while (v >= 1000 && i < units.length - 1) {
        v /= 1024;
        i++;
    }
    return `${i === 0 ? Math.round(v) : v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
};

export const fmt = {
    pct: v => `${Math.round(v)}%`,
    temp: v => `${Math.round(v)}°C`,
    bytes: v => scaled(v, UNITS),
    rate: v => `${scaled(v, RATE_UNITS)}/s`,
    mhz: v => (v >= 1000 ? `${(v / 1000).toFixed(2)} GHz` : `${Math.round(v)} MHz`),
    rpm: v => `${Math.round(v)} rpm`,
    volts: v => `${v.toFixed(2)} V`,
    watts: v => `${v.toFixed(1)} W`,
    load: v => v.toFixed(2),
    count: v => `${Math.round(v)}`,
    duration(seconds) {
        const m = Math.floor(seconds / 60);
        const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), min = m % 60;
        if (d > 0)
            return `${d} d ${h} h`;
        if (h > 0)
            return `${h} h ${min} min`;
        return `${min} min`;
    },
};

// Friendlier names for the hwmon chips people actually have.
const CHIPS = {
    coretemp: 'CPU', k10temp: 'CPU', zenpower: 'CPU', cpu_thermal: 'CPU',
    nvme: 'SSD', acpitz: 'ACPI', pch_cannonlake: 'Chipset', pch_cometlake: 'Chipset',
    pch_tigerlake: 'Chipset', pch_alderlake: 'Chipset', dell_smm: 'Dell', dell_ddv: 'Dell',
    iwlwifi_1: 'Wi-Fi', amdgpu: 'AMD GPU', BAT0: 'Battery', BAT1: 'Battery', spd5118: 'RAM',
};

export const chipName = chip => CHIPS[chip] ?? (/^pch_/.test(chip) ? 'Chipset' : chip);

export const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

// ---- the model ----------------------------------------------------------------------------------

// The top bar by default: what the old fixed readouts showed.
export const DEFAULT_PINS = ['cpu.usage', 'mem.usage', 'temp.package', 'gpu.state'];

// Sections in popup order. `icon` names a file in icons/ (ours) or a theme icon (`theme:`).
export const SECTIONS = [
    ['cpu', 'Processor', 'cpu'],
    ['mem', 'Memory', 'memory'],
    ['temp', 'Temperature', 'temperature'],
    ['fan', 'Fans', 'fan'],
    ['volt', 'Voltage', 'voltage'],
    ['sys', 'System', 'system'],
    ['net', 'Network', 'theme:network-transmit-receive-symbolic'],
    ['disk', 'Storage', 'theme:drive-harddisk-symbolic'],
    ['bat', 'Battery', 'theme:battery-good-symbolic'],
    ['gpu', 'Graphics', 'theme:video-display-symbolic'],
];

// The sections the popup keeps open: the ones you left open (a list, which may be empty; it also holds
// sections that are not on screen right now, such as Battery on a desk), or until you have opened or
// folded one, Processor, Memory, Network and Battery (Storage on a machine without a battery).
// shown: the set of section ids that are on screen.
export function sectionsToOpen(stored, shown) {
    if (stored[0] !== 'default')
        return stored;
    return ['cpu', 'mem', 'net', shown.has('bat') ? 'bat' : 'disk'].filter(id => shown.has(id));
}

// The icon a pinned value has in the top bar, where a row's own beats its section's.
const ROW_ICONS = {
    'net.down': 'theme:network-receive-symbolic',
    'net.up': 'theme:network-transmit-symbolic',
};

export const iconFor = id => ROW_ICONS[id] ?? SECTIONS.find(([s]) => s === id.split('.')[0])?.[2] ?? 'system';

const row = (id, label, raw, format, step = 0) =>
    ({id, label, raw, value: raw === null || raw === undefined ? '—' : format(raw), step});

// Readings (any part may be missing) → [{id, title, icon, summary, rows: [{id, label, value, raw, step}]}].
// Sections with nothing to show are left out; with hideZeros, so are rows whose value is 0.
export function buildSections(r, {hideZeros = false} = {}) {
    const out = {};
    const add = (section, ...rows) => (out[section] ??= []).push(...rows);

    if (r.cpu) {
        add('cpu', row('cpu.usage', 'Usage', r.cpu.usage, fmt.pct, 2));
        if (r.cpu.freq) {
            add('cpu', row('cpu.freq', 'Frequency', r.cpu.freq.avgMhz, fmt.mhz, 50));
            add('cpu', row('cpu.freq-max', 'Fastest core', r.cpu.freq.maxMhz, fmt.mhz, 50));
        }
        if (r.load) {
            add('cpu', row('cpu.load1', 'Load (1 min)', r.load.one, fmt.load, 0.05));
            add('cpu', row('cpu.load5', 'Load (5 min)', r.load.five, fmt.load, 0.05));
            add('cpu', row('cpu.load15', 'Load (15 min)', r.load.fifteen, fmt.load, 0.05));
        }
        (r.cpu.cores ?? []).forEach((v, i) => add('cpu', row(`cpu.core${i}`, `Core ${i}`, v, fmt.pct, 2)));
    }

    if (r.mem) {
        const m = r.mem;
        add('mem',
            row('mem.usage', 'Usage', m.usedPercent, fmt.pct, 1),
            row('mem.used', 'In use', (m.totalKb - m.availableKb) * 1024, fmt.bytes, 1 << 24),
            row('mem.available', 'Available', m.availableKb * 1024, fmt.bytes, 1 << 24),
            row('mem.cached', 'Cached', m.cachedKb * 1024, fmt.bytes, 1 << 24),
            row('mem.total', 'Total', m.totalKb * 1024, fmt.bytes));
        if (m.swapTotalKb > 0) {
            add('mem',
                row('mem.swap', 'Swap in use', m.swapUsedKb * 1024, fmt.bytes, 1 << 24),
                row('mem.swap-total', 'Swap', m.swapTotalKb * 1024, fmt.bytes));
        }
    }

    for (const t of r.temps ?? []) {
        const id = t.package ? 'temp.package' : `temp.${slug(`${t.chip}-${t.label}`)}`;
        const label = t.package ? 'Processor package' : `${chipName(t.chip)} ${t.label}`;
        add('temp', row(id, label, t.celsius, fmt.temp, 2));
    }
    for (const f of r.fans ?? [])
        add('fan', row(`fan.${slug(`${f.chip}-${f.label}`)}`, `${chipName(f.chip)} ${f.label}`, f.rpm, fmt.rpm, 50));
    for (const v of r.volts ?? [])
        add('volt', row(`volt.${slug(`${v.chip}-${v.label}`)}`, `${chipName(v.chip)} ${v.label}`, v.volts, fmt.volts, 0.02));

    if (r.uptime !== null && r.uptime !== undefined)
        add('sys', row('sys.uptime', 'Uptime', r.uptime, fmt.duration, 60));
    if (r.load) {
        add('sys', row('sys.processes', 'Processes', r.load.total, fmt.count));
        add('sys', row('sys.running', 'Running now', r.load.running, fmt.count));
    }

    if (r.net) {
        add('net',
            row('net.down', 'Download', r.net.down, fmt.rate, 1024),
            row('net.up', 'Upload', r.net.up, fmt.rate, 1024),
            row('net.down-total', 'Downloaded since boot', r.net.rx, fmt.bytes),
            row('net.up-total', 'Uploaded since boot', r.net.tx, fmt.bytes));
    }

    if (r.disk) {
        add('disk',
            row('disk.read', 'Reading', r.disk.read, fmt.rate, 1024),
            row('disk.write', 'Writing', r.disk.write, fmt.rate, 1024));
    }
    if (r.fs) {
        add('disk',
            row('disk.free', 'Free space', r.fs.free, fmt.bytes, 1 << 26),
            row('disk.used', 'In use', r.fs.size - r.fs.free, fmt.bytes, 1 << 26),
            row('disk.size', 'Size', r.fs.size, fmt.bytes));
    }

    if (r.battery) {
        const b = r.battery;
        add('bat', row('bat.percent', 'Charge', b.percent, fmt.pct, 1));
        if (b.status)
            add('bat', {id: 'bat.status', label: 'State', raw: null, value: b.status, step: 0});
        if (b.watts !== null && b.watts !== undefined)
            add('bat', row('bat.rate', b.status === 'Charging' ? 'Charging at' : 'Using', Math.abs(b.watts), fmt.watts, 0.2));
        if (b.timeLeft > 0)
            add('bat', row('bat.time', b.status === 'Charging' ? 'Until full' : 'Time left', b.timeLeft, fmt.duration, 60));
    }

    if (r.gpu) {
        const g = r.gpu;
        add('gpu', {id: 'gpu.state', label: g.name ?? 'NVIDIA GPU', raw: null, value: g.awake ? 'On' : 'Asleep', step: 0});
        if (g.awake && g.stats) {
            const s = g.stats;
            add('gpu',
                row('gpu.load', 'Usage', s.load, fmt.pct, 2),
                row('gpu.vram', 'Video memory in use', s.used === null ? null : s.used * 1048576, fmt.bytes, 1 << 24),
                row('gpu.power', 'Power', s.watts, fmt.watts, 0.5),
                row('gpu.temp', 'Temperature', s.temp, fmt.temp, 2));
        }
    }
    if (r.igpu)
        add('gpu', row('gpu.igpu', 'Integrated GPU clock', r.igpu.actMhz, fmt.mhz, 50));

    const sections = [];
    for (const [id, title, icon] of SECTIONS) {
        let rows = out[id] ?? [];
        if (hideZeros)
            rows = rows.filter(x => x.raw !== 0);
        if (rows.length === 0)
            continue;
        sections.push({id, title, icon, summary: summaryOf(id, rows), rows});
    }
    return sections;
}

// The value shown on a section's own line, next to its name.
function summaryOf(id, rows) {
    const get = rid => rows.find(x => x.id === rid);
    switch (id) {
    case 'temp':
        return (get('temp.package') ?? hottest(rows))?.value ?? '';
    case 'net': {
        const d = get('net.down'), u = get('net.up');
        return d && u ? `↓${d.value} ↑${u.value}` : '';
    }
    case 'disk':
        return get('disk.free') ? `${get('disk.free').value} free` : '';
    case 'sys':
        return get('sys.uptime') ? `Up ${get('sys.uptime').value}` : '';
    default:
        return rows[0].value;
    }
}

const hottest = rows => rows.reduce((a, b) => ((b.raw ?? -Infinity) > (a?.raw ?? -Infinity) ? b : a), null);

// Pins → what the top bar shows, in pin order: [{id, icon, value, raw, step}]. A pin whose reading
// isn't there (no NVIDIA card, no sensor, a value hidden as zero) is left out, not shown as a dash.
export function panelItems(pins, sections) {
    const rows = new Map();
    for (const s of sections)
        for (const x of s.rows)
            rows.set(x.id, x);
    return pins.filter(id => rows.has(id)).map(id => ({...rows.get(id), icon: iconFor(id)}));
}

// What a screen reader says for a row: "Processor Usage 12%, pinned".
// The pin is the toggle's checked state (the row is a toggle button), which a screen reader says on its
// own: saying it in the name too announced it twice.
export const rowName = (section, label, value) => `${section} ${label} ${value}`;

// Pin or unpin one row; a new pin goes at the end.
export const togglePin = (pins, id) => (pins.includes(id) ? pins.filter(p => p !== id) : [...pins, id]);

// What has to be read on a tick when the popup is shut: only what the pins show.
export function needed(pins) {
    const need = new Set();
    for (const id of pins) {
        const section = id.split('.')[0];
        if (section === 'cpu')
            need.add(/^cpu\.load/.test(id) ? 'load' : /^cpu\.freq/.test(id) ? 'freq' : 'stat');
        else if (section === 'sys')
            need.add(id === 'sys.uptime' ? 'uptime' : 'load');
        else if (section === 'temp')
            need.add(id === 'temp.package' ? 'package' : 'chips');
        else if (section === 'fan' || section === 'volt')
            need.add('chips');
        else if (section === 'disk')
            need.add(/^disk\.(read|write)$/.test(id) ? 'diskstats' : 'fs');
        else if (section === 'gpu')
            need.add(id === 'gpu.igpu' ? 'igpu' : 'nvidia');
        else
            need.add({mem: 'mem', net: 'net', bat: 'battery'}[section] ?? section);
    }
    return need;
}
