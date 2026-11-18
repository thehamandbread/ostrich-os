// tests/js/monitor-vitals.test.js: unit tests for monitor/vitals.js. Run with tests/js-test.sh.
import {
    fmt, buildSections, panelItems, togglePin, needed, iconFor, chipName, rowName, DEFAULT_PINS,
} from '../../modules/gnome/extensions/monitor/vitals.js';

let failures = 0;
function check(name, cond) {
    if (cond) {
        print(`ok - ${name}`);
    } else {
        failures++;
        print(`not ok - ${name}`);
    }
}

// formatting
check('bytes', fmt.bytes(512) === '512 B' && fmt.bytes(1536) === '1.5 KB' && fmt.bytes(2.6 * 1024 ** 3) === '2.6 GB' && fmt.bytes(50 * 1024 ** 3) === '50 GB');
check('rate', fmt.rate(2048) === '2.0 K/s' && fmt.rate(0) === '0 B/s' && fmt.rate(985 * 1024) === '985 K/s' && fmt.rate(12.4 * 1024 ** 2) === '12 M/s' && fmt.rate(999) === '999 B/s' && fmt.rate(1010) === '1.0 K/s');
check('clock', fmt.mhz(800) === '800 MHz' && fmt.mhz(2400) === '2.40 GHz');
check('duration', fmt.duration(59) === '0 min' && fmt.duration(3 * 3600 + 12 * 60) === '3 h 12 min' && fmt.duration(2 * 86400 + 3600) === '2 d 1 h');
check('chip names', chipName('coretemp') === 'CPU' && chipName('nvme') === 'SSD' && chipName('pch_meteorlake') === 'Chipset' && chipName('odd') === 'odd');

const readings = {
    cpu: {usage: 42, cores: [10, 0], freq: {avgMhz: 2400, maxMhz: 4100}},
    load: {one: 0.5, five: 0.4, fifteen: 0.3, running: 2, total: 811},
    uptime: 7200,
    mem: {totalKb: 8 * 1048576, availableKb: 4 * 1048576, usedPercent: 50, cachedKb: 1048576, swapTotalKb: 0, swapUsedKb: 0},
    temps: [
        {chip: 'coretemp', label: 'Package id 0', celsius: 55, package: true},
        {chip: 'coretemp', label: 'Core 0', celsius: 50},
        {chip: 'nvme', label: 'Composite', celsius: 38},
    ],
    fans: [{chip: 'dell_smm', label: 'Processor Fan', rpm: 0}],
    net: {rx: 1e9, tx: 1e8, down: 2048, up: 0},
    fs: {size: 500 * 1024 ** 3, free: 200 * 1024 ** 3},
    battery: {percent: 80, status: 'Discharging', watts: 11.5, timeLeft: 3 * 3600},
    gpu: {awake: false, stats: null, name: null},
};

const secs = buildSections(readings);
const ids = secs.map(s => s.id);
check('sections in order, empty ones left out', ids.join() === 'cpu,mem,temp,fan,sys,net,disk,bat,gpu');
const cpu = secs.find(s => s.id === 'cpu');
check('cpu summary is usage', cpu.summary === '42%');
check('cpu rows: usage, clocks, loads, cores', cpu.rows.map(r => r.id).join() ===
    'cpu.usage,cpu.freq,cpu.freq-max,cpu.load1,cpu.load5,cpu.load15,cpu.core0,cpu.core1');
const mem = secs.find(s => s.id === 'mem');
check('memory without swap has no swap rows', !mem.rows.some(r => r.id.startsWith('mem.swap')));
check('memory in use', mem.rows.find(r => r.id === 'mem.used').value === '4.0 GB');
const temp = secs.find(s => s.id === 'temp');
check('the average of all sensors comes first and leads the summary',
    temp.rows[0].id === 'temp.average' && temp.rows[0].value === '48°C' && temp.summary === '48°C');
check('package temp keeps its fixed id', temp.rows[1].id === 'temp.package' && temp.rows[1].value === '55°C');
check('one sensor: the average is that sensor (the default pin stays)', buildSections({temps: [{chip: 'acpitz', label: 'temp1', celsius: 40}]}, {}).find(s => s.id === 'temp').rows[0].value === '40°C');
check('other sensors get chip names', temp.rows.some(r => r.label === 'SSD Composite' && r.id === 'temp.nvme-composite'));
check('net summary has both ways', secs.find(s => s.id === 'net').summary === '↓2.0 K/s ↑0 B/s');
check('system summary reads Up and the time', secs.find(s => s.id === 'sys').summary === 'Up 2 h 0 min');
check('disk summary is free space', secs.find(s => s.id === 'disk').summary === '200 GB free');
check('battery time left', secs.find(s => s.id === 'bat').rows.find(r => r.id === 'bat.time').value === '3 h 0 min');
check('gpu asleep', secs.find(s => s.id === 'gpu').rows[0].value === 'Asleep');
check('missing readings show a dash', buildSections({cpu: {usage: null}})[0].rows[0].value === '—');

const hidden = buildSections(readings, {hideZeros: true});
check('hide zeros drops the idle fan section', !hidden.some(s => s.id === 'fan'));
check('hide zeros drops zero rows', !hidden.find(s => s.id === 'cpu').rows.some(r => r.id === 'cpu.core1'));
check('hide zeros keeps text rows', hidden.find(s => s.id === 'gpu').rows.length === 1);

// pins
const items = panelItems(['net.down', 'cpu.usage', 'fan.nothing'], secs);
check('panel follows pin order and skips missing', items.map(i => i.id).join() === 'net.down,cpu.usage');
check('panel icons: own, else section', items[0].icon === 'theme:network-receive-symbolic' && items[1].icon === 'cpu');
check('default pins all exist in the model', DEFAULT_PINS.every(id => iconFor(id) !== 'system'));
check('toggle pin adds at the end', togglePin(['a'], 'b').join() === 'a,b');
check('toggle pin removes', togglePin(['a', 'b'], 'a').join() === 'b');

// what a closed popup reads
const need = needed(DEFAULT_PINS);
// The average reads every sensor chip (owner, 2026-11-18: the average, not the package, by default).
check('default pins read stat, memory, the sensor chips and nvidia only',
    [...need].sort().join() === 'chips,mem,nvidia,stat');
check('rates and disks map to their sources', [...needed(['net.up', 'disk.read', 'disk.free', 'sys.uptime', 'cpu.load1'])].sort().join() ===
    'diskstats,fs,load,net,uptime');
check('no pins read nothing', needed([]).size === 0);

// screen reader names
check('row name says the value, not the pin (the toggle state does)', rowName('Processor', 'Usage', '12%', true) === 'Processor Usage 12%' &&
    rowName('Memory', 'Total', '16 GB', false) === 'Memory Total 16 GB');

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
