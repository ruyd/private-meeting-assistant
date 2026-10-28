#!/usr/bin/env python3
"""Run button for Claude desktop (.claude/launch.json): builds and launches the Debug app, then serves
a page on localhost that mirrors its windows, refreshed every second. The app itself opens as a
normal window on this Mac; use that one to click and type. The page has buttons to launch the app
again (if it was quit) or rebuild and relaunch it. Stopping the server quits the app.

The Debug app draws its own windows into mac/build/preview/ (`-previewSnapshots`, see
Debug/WindowSnapshots.swift), so no process needs Screen Recording permission.

    mac/scripts/preview-server.py [port]     (default 8765)
"""
import http.server
import json
import os
import signal
import subprocess
import sys
import threading

MAC_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_APP = os.path.join(MAC_DIR, "scripts", "run-app.sh")
SNAPSHOTS = os.path.join(MAC_DIR, "build", "preview")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
# What the page shows instead of the windows: build progress or failure; empty once the app runs.
status = "Starting…"
# One build or launch at a time.
busy = threading.Lock()

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Private Meeting Assistant</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 16px; font: 13px -apple-system, sans-serif; background: #121317; color: #ddd; }
  p { margin: 0 0 12px; color: #999; }
  header { display: flex; align-items: center; gap: 8px; margin-bottom: 14px; }
  header p { flex: 1; margin: 0; }
  button { font: inherit; padding: 5px 12px; border-radius: 7px; border: 1px solid #3a3d45; background: #23262d; color: #eee; cursor: pointer; }
  button.primary { background: #e5483d; border-color: #e5483d; color: #fff; }
  button:disabled { opacity: 0.45; cursor: default; }
  figure { margin: 0 0 20px; }
  figcaption { margin-bottom: 6px; font-weight: 600; }
  img { max-width: 100%; border-radius: 10px; box-shadow: 0 4px 24px #0008; }
</style></head>
<body>
<header>
  <p id="note">Live view of the app's windows. The app runs as a normal window on this Mac: click and type there.</p>
  <button id="launch" class="primary" onclick="launch(false)">Launch</button>
  <button id="rebuild" onclick="launch(true)" title="Build the current code, then relaunch">Rebuild &amp; Relaunch</button>
</header>
<div id="windows"></div>
<script>
const root = document.getElementById('windows');
const launchButton = document.getElementById('launch');
const rebuildButton = document.getElementById('rebuild');
let shown = '';
async function launch(build) {
  launchButton.disabled = rebuildButton.disabled = true;
  await fetch(`/launch?build=${build ? 1 : 0}`, { method: 'POST' });
}
async function refresh() {
  try {
    const { status, running, busy, windows: list } = await (await fetch('/windows')).json();
    launchButton.textContent = running ? 'Relaunch' : 'Launch';
    launchButton.className = running ? '' : 'primary';
    launchButton.disabled = rebuildButton.disabled = busy;
    const key = status || (running ? list.map(w => w.id + ' ' + w.title).join('|') : 'not running');
    if (key !== shown) {
      // The set of windows changed: lay the page out again.
      shown = key;
      root.innerHTML = '';
      if (status) {
        const pre = document.createElement('pre');
        pre.textContent = status;
        root.append(pre);
      } else if (!running) {
        root.innerHTML = '<p>The app isn’t running. Launch it with the button above.</p>';
      } else if (!list.length) {
        root.innerHTML = '<p>The app has no open windows.</p>';
      }
      for (const w of status || !running ? [] : list) {
        const figure = document.createElement('figure');
        const caption = document.createElement('figcaption');
        caption.textContent = w.title || 'Window';
        const img = document.createElement('img');
        img.dataset.id = w.id;
        figure.append(caption, img);
        root.append(figure);
      }
    }
    // Swap each image only once the new one has loaded, so nothing flickers.
    for (const img of root.querySelectorAll('img')) {
      const next = new Image();
      next.onload = () => { img.src = next.src; };
      next.src = `/shot/${img.dataset.id}.png?t=${Date.now()}`;
    }
  } catch (e) {}
  setTimeout(refresh, 1000);
}
refresh();
</script></body></html>"""


def app_running():
    return subprocess.run(["pgrep", "-f", "Private Meeting Assistant.app/Contents/MacOS/"], capture_output=True).returncode == 0


def clear_snapshots():
    # Old snapshots would show windows that are gone.
    os.makedirs(SNAPSHOTS, exist_ok=True)
    for name in os.listdir(SNAPSHOTS):
        os.remove(os.path.join(SNAPSHOTS, name))


def run_app(build):
    """Builds (if asked) and launches the app, quitting any running copy. Skipped if one is under way."""
    global status
    if not busy.acquire(blocking=False):
        return
    try:
        if build:
            status = "Building…"
            result = subprocess.run([RUN_APP, "build"], capture_output=True, text=True)
            print(result.stdout, result.stderr, flush=True)
            if result.returncode != 0:
                status = "Build failed:\n" + result.stdout + result.stderr
                return
        status = "Launching…"
        subprocess.run([RUN_APP, "quit"])
        clear_snapshots()
        subprocess.run([RUN_APP, "launch", "-previewSnapshots", SNAPSHOTS], check=False)
        status = ""
    finally:
        busy.release()


def windows():
    try:
        with open(os.path.join(SNAPSHOTS, "windows.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.reply(200, "text/html; charset=utf-8", PAGE.encode())
        elif self.path == "/windows":
            running = app_running()
            body = {"status": status, "running": running, "busy": busy.locked(), "windows": windows() if running else []}
            self.reply(200, "application/json", json.dumps(body).encode())
        elif self.path.startswith("/shot/"):
            wid = self.path[len("/shot/"):].split(".")[0]
            if not wid.isdigit() or int(wid) not in {w["id"] for w in windows()}:
                return self.reply(404, "text/plain", b"no such window")
            try:
                with open(os.path.join(SNAPSHOTS, f"{int(wid)}.png"), "rb") as f:
                    self.reply(200, "image/png", f.read())
            except OSError:
                self.reply(404, "text/plain", b"no snapshot yet")
        else:
            self.reply(404, "text/plain", b"not found")

    def do_POST(self):
        if self.path.startswith("/launch"):
            threading.Thread(target=run_app, args=("build=1" in self.path,), daemon=True).start()
            self.reply(202, "text/plain", b"started")
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
    def stop(*_):
        subprocess.run([RUN_APP, "quit"])
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    # Serve right away, so the preview opens (showing the status) while the app builds.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Preview on http://localhost:{PORT}", flush=True)

    run_app(build=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
