// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/signals.js: track signal connections so disable() can drop every one of them.
//
// An object that dies first (an actor's 'destroy', a window's 'unmanaged') is forgotten here when it
// does: disconnecting its handlers later, from disconnectAll(), hit an object that was gone and
// logged a warning for each (the journal gate caught focus's allow-list doing it). Only forgotten,
// not disconnected: other handlers of that same signal (often the owner's own cleanup) must still
// run, and disconnecting mid-emission skipped them; GLib drops a dead object's handlers itself.

import GObject from 'gi://GObject';

const DEATHS = ['destroy', 'unmanaged'];

export class Signals {
    constructor() {
        this._ids = [];
        this._watched = new Map(); // obj -> id of the handler on its death signal
    }

    connect(obj, signal, callback) {
        const id = obj.connect(signal, callback);
        this._ids.push([obj, id]);
        this._watch(obj);
        return id;
    }

    _watch(obj) {
        if (this._watched.has(obj) || !(obj instanceof GObject.Object))
            return;
        const death = DEATHS.find(d => GObject.signal_lookup(d, obj.constructor.$gtype));
        if (!death)
            return;
        this._watched.set(obj, obj.connect(death, () => this._forget(obj)));
    }

    _forget(obj) {
        this._ids = this._ids.filter(([o]) => o !== obj);
        this._watched.delete(obj);
    }

    disconnectAll() {
        for (const [obj, id] of [...this._ids, ...this._watched]) {
            try {
                obj.disconnect(id);
            } catch (e) {
                // The object may already be gone; nothing left to undo.
                console.debug(`signals: disconnect failed: ${e.message}`);
            }
        }
        this._ids = [];
        this._watched.clear();
    }
}
