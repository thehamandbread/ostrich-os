// tests/js/monitor-sources.test.js: unit tests for monitor/sources.js. Run with tests/js-test.sh.
import GLib from 'gi://GLib';

import {
    parseProcStat, cpuPercent, parseMeminfo, packageTemperature, batteryWatts,
    readChip, findHwmon, readBattery,
    parseLoadavg, parseUptime, parseNetDev, parseDiskstats, rate, cpuFrequency,
} from '../../modules/gnome/extensions/monitor/sources.js';

let failures = 0;
function check(name, cond) {
    if (cond) {
        print(`ok - ${name}`);
    } else {
        failures++;
        print(`not ok - ${name}`);
    }
}
const near = (a, b) => a !== null && Math.abs(a - b) < 1e-6;

// /proc/stat
const stat1 = parseProcStat('cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 50 0 25 400 25 0 0 0 0 0\ncpu1 50 0 25 400 25 0 0 0 0 0\nintr 1 2 3\n');
const stat2 = parseProcStat('cpu  200 0 100 1500 100 0 0 0 0 0\ncpu0 150 0 50 700 50 0 0 0 0 0\ncpu1 50 0 50 800 50 0 0 0 0 0\n');
check('proc/stat total parsed', stat1.total.busy === 150 && stat1.total.idle === 850);
check('proc/stat cores parsed', stat1.cores.length === 2);
check('cpu percent total', near(cpuPercent(stat1.total, stat2.total), (100 * 150) / (150 + 750)));
check('cpu percent per core', near(cpuPercent(stat1.cores[0], stat2.cores[0]), (100 * 125) / (125 + 325)));
check('cpu percent without interval is null', cpuPercent(stat1.total, stat1.total) === null);
check('cpu percent without prev is null', cpuPercent(null, stat1.total) === null);

// /proc/meminfo
const mem = parseMeminfo('MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    4000000 kB\n');
check('meminfo used percent', near(mem.usedPercent, 75));
check('meminfo missing fields is null', parseMeminfo('MemTotal: 1 kB\n') === null);
const mem2 = parseMeminfo('MemTotal: 8000 kB\nMemAvailable: 4000 kB\nBuffers: 100 kB\nCached: 900 kB\nSwapTotal: 2000 kB\nSwapFree: 1500 kB\n');
check('meminfo cache and swap', mem2.cachedKb === 1000 && mem2.swapTotalKb === 2000 && mem2.swapUsedKb === 500);
check('meminfo without swap lines', mem.swapTotalKb === 0 && mem.swapUsedKb === 0);

// load, uptime, network, disks, clocks
const load = parseLoadavg('0.52 0.40 0.31 2/811 12345\n');
check('loadavg', load.one === 0.52 && load.fifteen === 0.31 && load.running === 2 && load.total === 811);
check('loadavg junk is null', parseLoadavg('') === null && parseLoadavg(null) === null);
check('uptime', parseUptime('3600.5 7000.1\n') === 3600.5 && parseUptime('') === null);
const net = parseNetDev(`Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 9999 10 0 0 0 0 0 0 9999 10 0 0 0 0 0 0
  eth0: 1000 10 0 0 0 0 0 0 200 5 0 0 0 0 0 0
 wlan0: 500 3 0 0 0 0 0 0 50 1 0 0 0 0 0 0
`);
check('net/dev sums all but loopback', net.rx === 1500 && net.tx === 250);
check('net/dev empty is null', parseNetDev('Inter-|\n face |\n') === null);
const disks = parseDiskstats(`   7       0 loop0 10 0 800 0 0 0 0 0 0 0 0
 259       0 nvme0n1 100 0 2000 0 50 0 1000 0 0 0 0
 259       1 nvme0n1p1 100 0 2000 0 50 0 1000 0 0 0 0
   8       0 sda 1 0 10 0 1 0 10 0 0 0 0
`);
check('diskstats whole disks only', disks.read === 2010 * 512 && disks.write === 1010 * 512);
check('rate', rate(100, 300, 2) === 100 && rate(null, 5, 1) === null && rate(5, 1, 1) === null && rate(1, 2, 0) === null);
const f = cpuFrequency([2000000, 4000000, NaN]);
check('cpu frequency', f.avgMhz === 3000 && f.maxMhz === 4000 && cpuFrequency([NaN]) === null);

// temperatures
const sensors = [
    {chip: 'nvme', label: 'Composite', celsius: 38},
    {chip: 'coretemp', label: 'Core 0', celsius: 48},
    {chip: 'coretemp', label: 'Package id 0', celsius: 52},
];
check('package temp prefers coretemp package', packageTemperature(sensors) === 52);
check('package temp AMD Tctl', packageTemperature([{chip: 'k10temp', label: 'Tctl', celsius: 61}]) === 61);
check('package temp none', packageTemperature([{chip: 'nvme', label: 'Composite', celsius: 38}]) === null);

// battery
check('battery watts from power_now', near(batteryWatts({power_now: 12500000}), 12.5));
check('battery watts from current x voltage', near(batteryWatts({current_now: 1000000, voltage_now: 12000000}), 12));
check('battery watts unknown', batteryWatts({}) === null);

// sysfs fixtures (async I/O)
const root = GLib.dir_make_tmp('monitor-test-XXXXXX');
const write = (path, text) => {
    GLib.mkdir_with_parents(GLib.path_get_dirname(`${root}/${path}`), 0o755);
    GLib.file_set_contents(`${root}/${path}`, text);
};
write('hwmon/hwmon0/name', 'nvme\n');
write('hwmon/hwmon1/name', 'coretemp\n');
write('hwmon/hwmon1/temp1_input', '52000\n');
write('hwmon/hwmon1/temp1_label', 'Package id 0\n');
write('hwmon/hwmon1/temp2_input', '48000\n');
write('hwmon/hwmon1/fan1_input', '1800\n');
write('hwmon/hwmon1/in0_input', '1050\n');
write('hwmon/hwmon1/in0_label', 'Vcore\n');
write('ps/AC/type', 'Mains\n');
write('ps/BAT0/type', 'Battery\n');
write('ps/BAT0/status', 'Discharging\n');
write('ps/BAT0/current_now', '1000000\n');
write('ps/BAT0/voltage_now', '11500000\n');
write('ps/BAT0/capacity', '80\n');

const loop = new GLib.MainLoop(null, false);
(async () => {
    const chips = await findHwmon(`${root}/hwmon`);
    check('findHwmon maps names', chips.coretemp === `${root}/hwmon/hwmon1` && chips.nvme === `${root}/hwmon/hwmon0`);
    const {temps, fans} = await readChip('coretemp', chips.coretemp);
    check('readChip temps with labels', temps.length === 2 && temps.some(t => t.label === 'Package id 0' && t.celsius === 52));
    check('readChip unlabelled temp gets a name', temps.some(t => t.label === 'temp2' && t.celsius === 48));
    check('readChip fans', fans.length === 1 && fans[0].rpm === 1800);
    const {volts} = await readChip('coretemp', chips.coretemp);
    check('readChip voltages', volts.length === 1 && volts[0].label === 'Vcore' && near(volts[0].volts, 1.05));
    const bat = await readBattery(`${root}/ps`);
    check('readBattery finds the battery', bat && bat.status === 'Discharging' && bat.percent === 80 && near(bat.watts, 11.5));
    check('readBattery none', (await readBattery(`${root}/hwmon`)) === null);
})().catch(e => {
    failures++;
    print(`not ok - async tests threw: ${e}`);
}).finally(() => {
    GLib.spawn_command_line_sync(`rm -rf ${GLib.shell_quote(root)}`);
    loop.quit();
});
loop.run();

print(failures === 0 ? '# all passed' : `# ${failures} failed`);
if (failures > 0)
    imports.system.exit(1);
