// tests/vm/site-probe.js: runs INSIDE the test VM's desktop session. Opens one URL in a WebKitGTK 6
// window (the engine Ostrich Drawer uses, with its default user agent and a throwaway session),
// waits for the page to settle, and prints one JSON line: the final URL and the page's title and
// text, so drawer-test.sh --sites can spot "browser not supported" pages.
//
//   gjs -m site-probe.js URL [SETTLE_SECONDS] [USER_AGENT]
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';
import WebKit from 'gi://WebKit?version=6.0';

const [url, settleArg, userAgent] = ARGV;
const settle = Number(settleArg ?? 6);
Gtk.init();
const loop = GLib.MainLoop.new(null, false);
const win = new Gtk.Window({default_width: 1280, default_height: 800, title: 'site-probe'});
const view = new WebKit.WebView({network_session: WebKit.NetworkSession.new_ephemeral()});
if (userAgent)
    view.get_settings().set_user_agent(userAgent);
win.set_child(view);
win.present();

let done = false;
function finish(result) {
    if (done)
        return;
    done = true;
    print(JSON.stringify({url, final: view.get_uri(), ...result}));
    loop.quit();
}

view.connect('load-changed', (_v, ev) => {
    if (ev !== WebKit.LoadEvent.FINISHED)
        return;
    GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, settle, () => {
        view.evaluate_javascript('document.title + "\\n" + (document.body ? document.body.innerText.slice(0, 4000) : "")',
            -1, null, null, null, (v, res) => {
                try {
                    finish({text: v.evaluate_javascript_finish(res).to_string()});
                } catch (e) {
                    finish({error: e.message});
                }
            });
        return GLib.SOURCE_REMOVE;
    });
});
view.connect('load-failed', (_v, _ev, _uri, error) => {
    finish({error: error.message});
    return true;
});
GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 45, () => {
    finish({error: 'timed out'});
    return GLib.SOURCE_REMOVE;
});
view.load_uri(url);
loop.run();
