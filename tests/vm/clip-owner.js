// tests/vm/clip-owner.js: a small window that puts a 1 x 1 PNG on the clipboard when it is clicked
// (a clipboard owner needs an input event's serial) or gets the focus, then keeps it there, as a screenshot tool does.
// For drawer-test.sh. Quits after 90 s.
imports.gi.versions.Gtk = '4.0';
imports.gi.versions.Gdk = '4.0';
const {Gtk, Gdk, GLib} = imports.gi;

Gtk.init();
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const loop = GLib.MainLoop.new(null, false);
const win = new Gtk.Window({default_width: 300, default_height: 200, title: 'clip-owner'});
win.set_child(new Gtk.Label({label: 'click to copy an image'}));
const copy = () => Gdk.Display.get_default().get_clipboard()
    .set_content(Gdk.ContentProvider.new_for_bytes('image/png', GLib.base64_decode(PNG)));
const click = new Gtk.GestureClick();
click.connect('pressed', copy);
win.add_controller(click);
// Also when the window gets the focus (a keyboard focus-in is a serial too), so it does not depend
// on where the pointer is.
win.connect('notify::is-active', () => {
    if (win.is_active)
        copy();
});
win.present();
GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 90, () => {
    loop.quit();
    return GLib.SOURCE_REMOVE;
});
loop.run();
