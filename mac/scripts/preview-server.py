#!/usr/bin/env python3
"""Run button for Claude desktop (.claude/launch.json): builds and launches the Debug app, then serves
a page on localhost that mirrors its windows, refreshed every second. The app itself opens as a
normal window on this Mac; use that one to click and type. Stopping the server quits the app.

    mac/scripts/preview-server.py [port]     (default 8765)
"""
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading

MAC_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_APP = os.path.join(MAC_DIR, "scripts", "run-app.sh")
HELPER = os.path.join(MAC_DIR, "build", "app-windows")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
# What the page shows above the windows: build progress or failure; empty once the app runs.
status = "Starting…"

HELPER_SOURCE = """
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "Private Meeting Assistant" && (w["kCGWindowLayer"] as? Int) == 0 {
    print(w["kCGWindowNumber"] ?? "", w["kCGWindowName"] ?? "")
}
"""

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Private Meeting Assistant</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 16px; font: 13px -apple-system, sans-serif; background: #121317; color: #ddd; }
  p { margin: 0 0 12px; color: #999; }
  figure { margin: 0 0 20px; }
  figcaption { margin-bottom: 6px; font-weight: 600; }
  img { max-width: 100%; border-radius: 10px; box-shadow: 0 4px 24px #0008; }
</style></head>
<body>
<p>Live view of the app's windows. The app runs as a normal window on this Mac: click and type there.</p>
<div id="windows"></div>
<script>
function noCapture() {
  const p = document.createElement('p');
  p.textContent = 'The app is running in its own window. To mirror it here, allow Claude under System Settings › Privacy & Security › Screen & System Audio Recording, then restart Claude and this preview.';
  return p;
}
async function refresh() {
  try {
    const { status, windows: list } = await (await fetch('/windows')).json();
    const root = document.getElementById('windows');
    if (status) root.innerHTML = '<pre></pre>', root.firstChild.textContent = status;
    else if (!list.length) root.innerHTML = '<p>The app has no open windows.</p>';
    else root.innerHTML = list.map(w =>
      `<figure><figcaption>${w.title || 'Window'}</figcaption><img src="/shot/${w.id}.png?t=${Date.now()}" onerror="this.replaceWith(noCapture())"></figure>`).join('');
  } catch (e) {}
  setTimeout(refresh, 1000);
}
refresh();
</script></body></html>"""


def windows():
    try:
        out = subprocess.run([HELPER], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    result = []
    for line in out.splitlines():
        wid, _, title = line.partition(" ")
        if wid.isdigit():
            result.append({"id": int(wid), "title": title})
    return result


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.reply(200, "text/html; charset=utf-8", PAGE.encode())
        elif self.path == "/windows":
            self.reply(200, "application/json", json.dumps({"status": status, "windows": windows()}).encode())
        elif self.path.startswith("/shot/"):
            wid = self.path[len("/shot/"):].split(".")[0]
            if not wid.isdigit() or int(wid) not in {w["id"] for w in windows()}:
                return self.reply(404, "text/plain", b"no such window")
            with tempfile.NamedTemporaryFile(suffix=".png") as f:
                subprocess.run(["screencapture", "-x", "-o", "-l", wid, f.name], capture_output=True, timeout=10)
                png = f.read()
            # Empty when the process running this server (Claude, or a terminal) lacks Screen Recording.
            if png:
                self.reply(200, "image/png", png)
            else:
                self.reply(503, "text/plain", b"screen recording not allowed")
        else:
            self.reply(404, "text/plain", b"not found")

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    os.makedirs(os.path.dirname(HELPER), exist_ok=True)
    if not os.path.exists(HELPER):
        with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
            f.write(HELPER_SOURCE)
        subprocess.run(["swiftc", "-O", f.name, "-o", HELPER], check=True)
        os.unlink(f.name)

    def stop(*_):
        subprocess.run([RUN_APP, "quit"])
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    # Serve right away, so the preview opens (showing the status) while the app builds.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Preview on http://localhost:{PORT}", flush=True)

    global status
    status = "Building…"
    build = subprocess.run([RUN_APP, "build"], capture_output=True, text=True)
    print(build.stdout, build.stderr, flush=True)
    if build.returncode != 0:
        status = "Build failed:\n" + build.stdout + build.stderr
    else:
        status = "Launching…"
        subprocess.run([RUN_APP, "launch"], check=False)
        status = ""
    threading.Event().wait()


if __name__ == "__main__":
    main()
