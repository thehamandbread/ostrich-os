import gi, sys
gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")
from gi.repository import Gtk, Adw, GLib
def on_activate(app):
    win = Adw.ApplicationWindow(application=app, default_width=480, default_height=300)
    box = Adw.ToolbarView(); box.add_top_bar(Adw.HeaderBar())
    page = Adw.StatusPage(title="Hello, Ostrich", description="A libadwaita window rendered with no display attached.", icon_name="emblem-ok-symbolic")
    b = Gtk.Button(label="Continue", halign=Gtk.Align.CENTER); b.add_css_class("suggested-action"); b.add_css_class("pill")
    page.set_child(b); box.set_content(page); win.set_content(box); win.present()
    GLib.timeout_add(1500, lambda: (app.quit(), False)[1])
app = Adw.Application(application_id="org.example.Hello"); app.connect("activate", on_activate); app.run(None)
