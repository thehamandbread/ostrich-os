// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/motion.js: one way to animate, for every extension. Three durations, eased out, through
// GNOME's own ease(), so "Animations" off (power saver turns it off), the Tweaks animation speed
// and GNOME's own scaling all apply with no code of ours. On top of ease():
//   - reduced motion (Accessibility > Seeing > Reduced Motion): nothing moves; the change happens
//     at once, and only a fade is animated, quickly. GNOME Shell 50 doesn't read that setting
//     itself, so it is read here; at the Shell 51 port, use St's own reduced-motion support instead.
//   - a stale animation's callback never runs: GNOME calls onStopped for an animation that a newer
//     one interrupted, so a slide-out cut short by a slide-in would otherwise still finish its work
//     (minimise the window it was hiding) after the slide-in began.
// Animate only position, scale and opacity (never a blur or a layout), so the GPU only composites.
// Vendored into each extension at build time (see build.sh); never shared at runtime.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';

export const QUICK = 120; // hover, previews, a fade, a close
export const STANDARD = 170; // a panel opening (the drawer), the dock showing
export const SLOW = 200; // the longest anything takes (the dock hiding)

const A11Y = 'org.gnome.desktop.a11y.interface';
let a11y; // undefined: not looked up yet; null: no such schema

function reducedMotion() {
    if (a11y === undefined) {
        const schema = Gio.SettingsSchemaSource.get_default()?.lookup(A11Y, true);
        a11y = schema?.has_key('reduced-motion') ? new Gio.Settings({schema_id: A11Y}) : null;
    }
    return a11y?.get_string('reduced-motion') === 'reduce';
}

const latest = new WeakMap(); // actor → the token of its newest animation

// Eases actor to props (Clutter properties) over duration ms. onDone(finished) runs once when the
// animation ends, unless a newer animate() on the same actor has replaced it. mode defaults to
// ease-out; pass EASE_IN_QUAD for things leaving the screen.
export function animate(actor, props, {duration = STANDARD, mode = Clutter.AnimationMode.EASE_OUT_QUAD, onDone} = {}) {
    const token = (latest.get(actor) ?? 0) + 1;
    latest.set(actor, token);
    actor.remove_all_transitions();
    let eased = props;
    if (reducedMotion()) {
        // Moves happen at once; only the fade is animated.
        const {opacity, ...moves} = props;
        actor.set(moves);
        if (opacity === undefined) {
            onDone?.(true);
            return;
        }
        eased = {opacity};
        duration = QUICK;
    }
    actor.ease({
        ...eased,
        duration,
        mode,
        onStopped: finished => {
            if (latest.get(actor) === token)
                onDone?.(finished);
        },
    });
}

// Stops actor's animation where it is; its callback won't run.
export function stop(actor) {
    latest.set(actor, (latest.get(actor) ?? 0) + 1);
    actor.remove_all_transitions();
}

// ---- the motion template: how every Ostrich surface comes out of where it belongs and goes back
// One style for all of them: Spring. It grows out of a small copy at the source
// and springs just past full size before settling (ease-out-back, about cubic-bezier(0.34, 1.56,
// 0.64, 1)); it goes back faster, speeding up, into the source.
//
// Cost: while it moves, the surface is drawn once into a texture (offscreen redirect) and only that
// picture is moved, scaled and faded; its text, blur and layout are never redrawn mid-motion.

export const POP_IN = 280; // coming out
export const POP_OUT = 140; // going back
const POP_IN_MODE = Clutter.AnimationMode.EASE_OUT_BACK; // the spring: a little past, then settle
const POP_OUT_MODE = Clutter.AnimationMode.EASE_IN_QUAD;
const POP_FROM = 0.2; // its size at the source

function rectOf(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x, y, width, height};
}

// Where `actor` is laid out on the stage, leaving out its own scale and translation.
function laidOut(actor) {
    const [px, py] = actor.get_parent()?.get_transformed_position() ?? [0, 0];
    return {x: px + actor.x, y: py + actor.y, width: actor.width, height: actor.height};
}

// The transform that puts a small copy of `actor` (laid out at `at`, pivot `pivot`) at the middle
// of `source`.
function fromSource(at, source, pivot) {
    const [px, py] = pivot;
    return {
        scale_x: POP_FROM,
        scale_y: POP_FROM,
        translation_x: source.x + source.width / 2 - (at.x + at.width * px),
        translation_y: source.y + source.height / 2 - (at.y + at.height * py),
    };
}

/**
 * Brings `actor` out of `source`: it starts over the source and settles where it is laid out.
 *
 * @param {Clutter.Actor} actor  already placed (position and size), with its parent
 * @param {Clutter.Actor} source  the thing it belongs to (the monitor, the clock, a dock icon)
 * @param {object} [o]
 * @param {number[]} [o.pivot]  the point of `actor` that comes out of the source, [0..1, 0..1]
 * @param {{x, y, width, height}} [o.at]  where `actor` is, if it isn't allocated yet
 * @param {() => void} [o.onDone]
 */
export function popOut(actor, source, {pivot = [0.5, 0], at = null, onDone} = {}) {
    const place = at ?? laidOut(actor);
    actor.set_pivot_point(...pivot);
    actor.set({opacity: 0, ...fromSource(place, rectOf(source), pivot)});
    actor.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);
    animate(actor, {opacity: 255, scale_x: 1, scale_y: 1, translation_x: 0, translation_y: 0}, {
        duration: POP_IN, mode: POP_IN_MODE,
        onDone: () => {
            actor.set_offscreen_redirect(Clutter.OffscreenRedirect.AUTOMATIC_FOR_OPACITY);
            onDone?.();
        },
    });
}

/** Takes `actor` back into `source`; onDone runs at the end (usually: hide or destroy it). */
export function retreat(actor, source, {pivot = [0.5, 0], onDone} = {}) {
    actor.set_pivot_point(...pivot);
    actor.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);
    animate(actor, {opacity: 0, ...fromSource(laidOut(actor), rectOf(source), pivot)}, {
        duration: POP_OUT, mode: POP_OUT_MODE,
        onDone: () => {
            actor.set_offscreen_redirect(Clutter.OffscreenRedirect.AUTOMATIC_FOR_OPACITY);
            onDone?.();
        },
    });
}
