// tests/vm/clip-check.js: prints the formats on the clipboard (for drawer-test.sh and debugging).
imports.gi.versions.Gtk = '4.0';
imports.gi.versions.Gdk = '4.0';
const {Gtk, Gdk, GLib} = imports.gi;

Gtk.init();
const win = new Gtk.Window({default_width: 10, default_height: 10});
win.present();
const loop = GLib.MainLoop.new(null, false);
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
    print(`clipboard: ${Gdk.Display.get_default().get_clipboard().get_formats().to_string()}`);
    loop.quit();
    return GLib.SOURCE_REMOVE;
});
loop.run();
