// tests/vm/paste-probe.js: does a WebKitGTK view get what is pasted into it? Puts an image or text
// on the clipboard (from this process: a clipboard owner has to be a focused window), loads argv[0],
// and waits for a real Ctrl+V sent from outside (vm.sh key). The page reports what it got
// (paste-server.py). argv: URL, 'image'|'text'|'none' (leave the clipboard to whoever owns it), 'plain'|'clipboard' (the clipboard setting).
// Run in the VM's session with gir1.2-webkit-6.0.
imports.gi.versions.Gtk = '4.0';
imports.gi.versions.Gdk = '4.0';
imports.gi.versions.WebKit = '6.0';
const {Gtk, Gdk, WebKit, GLib} = imports.gi;

Gtk.init();
const [url, what, variant] = ARGV;
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const loop = GLib.MainLoop.new(null, false);
const view = new WebKit.WebView();
if (variant === 'clipboard')
    view.get_settings().set_javascript_can_access_clipboard(true);
const win = new Gtk.Window({default_width: 600, default_height: 400, child: view});
win.present();
const clipboard = Gdk.Display.get_default().get_clipboard();
// A clipboard owner needs an input event's serial, so it takes the clipboard at the first click.
const own = () => {
    if (what === 'none' || SYNTH[what])
        return;
    clipboard.set_content(what === 'image'
        ? Gdk.ContentProvider.new_for_bytes('image/png', GLib.base64_decode(PNG))
        : Gdk.ContentProvider.new_for_bytes('text/plain;charset=utf-8', new TextEncoder().encode('hello')));
};
const click = new Gtk.GestureClick();
click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
click.connect('pressed', own);
win.add_controller(click);
view.load_uri(url);
const SYNTH = {
    // What the drawer does today, and the alternative: a plain Event carrying clipboardData.
    clipboardevent: `new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true, composed: true})`,
    plainevent: `Object.assign(new Event('paste', {bubbles: true, cancelable: true, composed: true}), {})`,
};
view.connect('load-changed', (_v, ev) => {
    if (ev !== WebKit.LoadEvent.FINISHED)
        return;
    view.evaluate_javascript('document.getElementById("e").focus()', -1, null, null, null, null);
    if (SYNTH[what]) {
        const script = `(() => { const bytes = Uint8Array.from(atob('${PNG}'), c => c.charCodeAt(0));
            const dt = new DataTransfer(); dt.items.add(new File([bytes], 'image.png', {type: 'image/png'}));
            const ev = ${SYNTH[what]};
            if ('${what}' === 'plainevent') Object.defineProperty(ev, 'clipboardData', {value: dt});
            document.activeElement.dispatchEvent(ev); })()`;
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            view.evaluate_javascript(script, -1, null, null, null, null);
            return GLib.SOURCE_REMOVE;
        });
    }
});
GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, SYNTH[what] ? 6 : 14, () => {
    loop.quit();
    return GLib.SOURCE_REMOVE;
});
loop.run();
