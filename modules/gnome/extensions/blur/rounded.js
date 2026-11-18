// SPDX-License-Identifier: GPL-2.0-or-later
// blur/rounded.js: masks an actor to a rounded rectangle (for the dock and menu backdrops).
// Works with both Clutter shader APIs: the snippet API (newer Mutter) and the shader-source one.
// Either way the shader is the class's, compiled once: a per-instance set_shader_source compiled
// a program for every mask, and the dock's (made anew each time it's switched on) piled up.

import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import GObject from 'gi://GObject';

const DECLARATIONS = `
uniform sampler2D tex;
uniform float radius;
uniform float width;
uniform float height;

float coverage(vec2 p) {
    vec2 c = clamp(p, vec2(radius), vec2(width, height) - vec2(radius));
    float d = length(p - c);
    return clamp(radius + 0.5 - d, 0.0, 1.0);
}`;

const BODY = `
    vec2 uv = cogl_tex_coord_in[0].xy;
    vec4 c = texture2D(tex, uv);
    float a = coverage(uv * vec2(width, height));
    cogl_color_out = vec4(c.rgb * a, c.a * a);`;

const USES_SNIPPETS = typeof Clutter.ShaderEffect.new_with_snippet === 'function';

class RoundedMaskBase extends Clutter.ShaderEffect {
    constructor(radius) {
        super();
        this._radius = radius;
    }

    vfunc_paint_target(node, paintContext) {
        const actor = this.get_actor();
        if (actor) {
            const [w, h] = actor.get_size();
            this.set_uniform_value('tex', 0);
            this.set_uniform_value('width', parseFloat(w));
            this.set_uniform_value('height', parseFloat(h));
            this.set_uniform_value('radius', parseFloat(Math.min(this._radius, w / 2, h / 2)) - 1e-6);
        }
        super.vfunc_paint_target(node, paintContext);
    }
}

if (USES_SNIPPETS) {
    Object.defineProperty(RoundedMaskBase.prototype, 'vfunc_get_static_snippet', {
        value() {
            const snippet = Cogl.Snippet.new(Cogl.SnippetHook.FRAGMENT, DECLARATIONS, null);
            snippet.set_replace(BODY);
            return snippet;
        },
    });
} else {
    Object.defineProperty(RoundedMaskBase.prototype, 'vfunc_get_static_shader_source', {
        value() {
            return `${DECLARATIONS}\nvoid main(void) {${BODY}\n}`;
        },
    });
}

export const RoundedMask = GObject.registerClass(RoundedMaskBase);
