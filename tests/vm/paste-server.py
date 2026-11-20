#!/usr/bin/env python3
# tests/vm/paste-server.py: a page with a text box that reports what a paste carried, for
# drawer-test.sh. GET / serves the page; the page's requests to /log?... are appended to the file
# named by argv[2] (one line each). Run: paste-server.py PORT LOGFILE
import http.server
import sys

PAGE = b"""<title>paste test</title>
<div id=e contenteditable autofocus style="width:100vw;height:100vh;font:24px sans-serif">paste here</div>
<script>
const log = q => fetch('/log?' + q);
e.addEventListener('paste', ev => {
  const d = ev.clipboardData;
  const items = [...d.items].map(i => i.kind + ':' + i.type).join(',');
  log('paste=' + encodeURIComponent(items) + '&types=' + encodeURIComponent([...d.types].join(',')) +
      '&files=' + d.files.length + '&text=' + encodeURIComponent(d.getData('text/plain')));
  setTimeout(() => log('inserted_images=' + e.querySelectorAll('img').length), 500);
});
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/log?"):
            with open(sys.argv[2], "a") as f:
                f.write(self.path[5:] + "\n")
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
