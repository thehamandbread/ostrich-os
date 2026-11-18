// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/battery.js: the battery rules, pure so the gjs unit tests can run them.

// UPower device states (org.freedesktop.UPower.Device.State).
export const UPOWER_DISCHARGING = 2;

/**
 * What the low-battery rule should do now.
 *
 * @param {object} s
 * @param {boolean} s.onBattery   UPower OnBattery
 * @param {number} s.percent      battery charge, 0-100
 * @param {string} s.profile      active power-profiles-daemon profile
 * @param {number} s.threshold    switch to power saver at or below this percent (0 = rule off)
 * @param {string} s.autoFrom     the profile the rule switched away from ('' if it hasn't)
 * @returns {{switchTo: string, autoFrom: string} | null} the profile to set and the new autoFrom
 */
export function lowBatteryRule({onBattery, percent, profile, threshold, autoFrom}) {
    // Plugged in again: give back what the rule took away (unless the user changed it since).
    if (!onBattery && autoFrom !== '') {
        return profile === 'power-saver'
            ? {switchTo: autoFrom, autoFrom: ''}
            : {switchTo: null, autoFrom: ''};
    }
    if (onBattery && threshold > 0 && percent <= threshold && profile !== 'power-saver' && autoFrom === '')
        return {switchTo: 'power-saver', autoFrom: profile};
    return null;
}

/**
 * The desktop settings power saver changes, and the values to put back after.
 * Each entry: [schema, key, saver value].
 */
export const SAVER_DESKTOP = [
    ['org.gnome.desktop.session', 'idle-delay', 120], // dim and blank sooner (seconds)
];

/**
 * The idle delay only shortens: if the user's own is shorter already, it stays, and "never" (0) is a
 * choice the user made, so it stays too.
 *
 * @param {string} key
 * @param {*} saverValue
 * @param {*} current
 * @returns {*} the value to use in power saver
 */
export function saverValue(key, saverValue, current) {
    if (key === 'idle-delay' && current < saverValue)
        return current;
    return saverValue;
}
