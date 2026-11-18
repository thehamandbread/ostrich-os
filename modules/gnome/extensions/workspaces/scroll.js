// SPDX-License-Identifier: GPL-2.0-or-later
// workspaces/scroll.js: one scroll movement moves one workspace, from a wheel or a touchpad.
// Pure (no GNOME Shell imports) so tests/js can run it.
//
// GNOME 50 steps once, then blocks for 150 ms after the step (windowManager.js SCROLL_TIMEOUT_TIME).
// A touchpad swipe lasts longer than that, so it stepped several times. Here the block lasts until
// scrolling has been quiet for those 150 ms, so a long swipe or a fast flick of the wheel is one step.
export const QUIET_MS = 150;

export class ScrollGate {
    constructor() {
        this._last = -Infinity;
        this._sum = 0;
        this._locked = false;
    }

    // `time` in ms (the event's time); `delta` a wheel click (+-1) or a touchpad's smooth amount.
    // Returns -1, 0 or 1: the workspaces to move.
    step(time, delta) {
        if (time - this._last >= QUIET_MS) {
            this._locked = false;
            this._sum = 0;
        }
        this._last = time;
        if (this._locked)
            return 0;
        this._sum += delta;
        if (Math.abs(this._sum) < 1)
            return 0;
        this._locked = true;
        return Math.sign(this._sum);
    }
}
