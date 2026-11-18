// SPDX-License-Identifier: GPL-2.0-or-later
// The early warning before memory runs out: a machine that fills its memory and swap grinds to a
// halt instead of closing anything (one laptop froze every few days).

export const WARN_PERCENT = 85;
export const CLEAR_PERCENT = 75;

/**
 * How full memory and swap are together, in percent; null without a reading.
 *
 * @param {{totalKb: number, availableKb: number, swapTotalKb: number, swapUsedKb: number}|null} mem
 * @returns {number|null}
 */
export function memoryPressure(mem) {
    if (!mem?.totalKb)
        return null;
    const used = mem.totalKb - mem.availableKb + (mem.swapUsedKb ?? 0);
    return (100 * used) / (mem.totalKb + (mem.swapTotalKb ?? 0));
}

/**
 * Warn once when it passes WARN_PERCENT, and again only after it has dropped below CLEAR_PERCENT.
 *
 * @param {number|null} pressure
 * @param {boolean} warned whether the last warning is still standing
 * @returns {{warn: boolean, warned: boolean}}
 */
export function memoryWarningRule(pressure, warned) {
    if (pressure === null)
        return {warn: false, warned};
    if (!warned && pressure >= WARN_PERCENT)
        return {warn: true, warned: true};
    return {warn: false, warned: warned && pressure >= CLEAR_PERCENT};
}

/**
 * The app holding the most memory, from [name, kB, scope] for each of its processes (a browser and
 * its tabs add up), or null. `scopes`: its systemd scopes, which "End app" stops.
 *
 * @param {Array<[string, number, string?]>} processes
 * @returns {{name: string, kb: number, scopes: string[]}|null}
 */
export function biggestApp(processes) {
    const total = new Map();
    for (const [name, kb, scope] of processes) {
        const t = total.get(name) ?? {name, kb: 0, scopes: []};
        t.kb += kb;
        if (scope && !t.scopes.includes(scope))
            t.scopes.push(scope);
        total.set(name, t);
    }
    let best = null;
    for (const t of total.values()) {
        if (!best || t.kb > best.kb)
            best = t;
    }
    return best;
}

/** Whether warningText names the app (it holds a tenth of memory), so End app can be offered. */
export function blames(app, totalKb) {
    return Boolean(app && app.kb >= totalKb / 10);
}

/**
 * @param {{name: string, kb: number}|null} app
 * @param {number} totalKb the machine's memory: an app is named only if it holds a tenth of it
 *     (the memory may be in something that isn't an app, like a program run in a terminal)
 * @returns {string} the notification's body
 */
export function warningText(app, totalKb) {
    const named = blames(app, totalKb);
    const what = named ? `${app.name} is using about ${(app.kb / 1048576).toFixed(1)} GB. ` : '';
    return `${what}Closing tabs or apps you aren't using frees it before the computer slows down.`;
}
