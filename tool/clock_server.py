import http.server
import socketserver
import sys
import time

# Serves a full-screen millisecond clock for the end-to-end latency baseline.
#
# The page renders on the phone; its digits are read back from a PrintWindow
# capture of the native overlay. The digits show *desktop* time: the page syncs
# against /time with several round trips and keeps the lowest-RTT offset, so
# latency = captureTimeMs - shownDigits needs no manual phone/PC calibration.
#
# Served on 127.0.0.1 only; the phone reaches it through `adb reverse
# tcp:8080 tcp:8080`, which avoids Windows Firewall inbound rules entirely.

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

PAGE = """<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  html,body { margin:0; padding:0; background:#000; color:#fff;
              font-family: ui-monospace, monospace; height:100%; }
  #wrap { display:flex; align-items:center; justify-content:center;
          height:100vh; }
  #t { font-size: 26vw; letter-spacing: 0.02em; line-height: 1; }
</style>
<div id="wrap"><div id="t">-----</div></div>
<script>
  let skew = 0;
  const node = document.getElementById('t');

  async function sync() {
    let best = null;
    for (let i = 0; i < 6; i++) {
      const t0 = Date.now();
      try {
        const response = await fetch('/time', { cache: 'no-store' });
        const serverMs = Number(await response.text());
        const t1 = Date.now();
        const rtt = t1 - t0;
        const candidate = { skew: serverMs + rtt / 2 - t1, rtt };
        if (!best || candidate.rtt < best.rtt) best = candidate;
      } catch (e) { /* retry */ }
      await new Promise(resolve => setTimeout(resolve, 60));
    }
    if (best) skew = best.skew;
  }

  function tick() {
    const v = (Date.now() + skew) % 100000;
    node.textContent = String(Math.floor(v)).padStart(5, '0');
    requestAnimationFrame(tick);
  }

  sync();
  tick();
  setInterval(sync, 5000);
</script>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, body, content_type):
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802 - http.server API
        if self.path.startswith('/time'):
            self._send(str(int(time.time() * 1000)), 'text/plain')
            return
        self._send(PAGE, 'text/html; charset=utf-8')

    def log_message(self, fmt, *args):
        pass


class Server(socketserver.TCPServer):
    allow_reuse_address = True


with Server(('127.0.0.1', PORT), Handler) as httpd:
    print('clock server listening on 127.0.0.1:%d' % PORT, flush=True)
    httpd.serve_forever()
