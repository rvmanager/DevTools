
mitmdump quick-reminder
A short, practical README you can skim when you need to run mitmdump + your hex/filter script on macOS.

Quick command
mitmdump --flow-detail 2 --anticomp --anticache --showhost --rawtcp --http2 -s filter_script_hex.py

What you should see:
Loading script filter_script_hex.py
HTTP(S) proxy listening at *:8080.

What the flags do (one-liners)
--flow-detail 2 — headers + small bodies (moderate verbosity).
--anticomp — ask server to stop gzip/deflate (see raw content).
--anticache — avoid cached responses.
--showhost — include host/SNI in request lines.
--rawtcp — capture raw TCP flows (non-HTTP).
--http2 — decode HTTP/2.
-s filter_script_hex.py — run your Python hook for custom logging/filtering.


macOS proxy)
System Settings → Network → choose interface → Details (Advanced) → Proxies:
Enable Web proxy (HTTP) and Secure web proxy (HTTPS).
Server: 127.0.0.1 Port: 8080
Add bypasses (e.g., *.local,169.254/16) if needed.

Terminal alternative:
sudo networksetup -setwebproxy "Wi-Fi" 127.0.0.1 8080
sudo networksetup -setsecurewebproxy "Wi-Fi" 127.0.0.1 8080

# disable later
sudo networksetup -setwebproxystate "Wi-Fi" off
sudo networksetup -setsecurewebproxystate "Wi-Fi" off

HTTPS 
With mitmdump running, open http://mitm.it on the proxied machine.

Download macOS cert, import into Keychain Access, set Trust → Always Trust.
Remove/untrust when finished.
Filter script (reminder)

Your filter_script_hex.py should:
Log request/response metadata (method, host, path, status).
Hex-dump bodies (truncate large bodies; write to files if needed).
Handle tcp_message for raw TCP when --rawtcp is used.

Minimal structure:
from mitmproxy import ctx, http, tcp
import binascii

MAX = 512

def format_hex(b: bytes):
    if not b: return "<empty>"
    return binascii.hexlify(b[:MAX]).decode() + ("... (truncated)" if len(b)>MAX else "")

def request(flow: http.HTTPFlow):
    ctx.log.info(f"REQ {flow.request.method} {flow.request.host}{flow.request.path}")
    ctx.log.info(format_hex(flow.request.content))

def response(flow: http.HTTPFlow):
    ctx.log.info(f"RES {flow.response.status_code} {flow.request.host}{flow.request.path}")
    ctx.log.info(format_hex(flow.response.content))

def tcp_message(flow: tcp.TCPFlow):
    ctx.log.info("RAW TCP")
    for m in flow.messages:
        ctx.log.info(format_hex(m.content))
(Adjust MAX, write bodies to disk if you need full captures.)

Save / replay flows

Save:
mitmdump -w /tmp/capture.mitm --anticomp --anticache --showhost --rawtcp --http2 -s filter_script_hex.py

Replay / inspect later:
mitmdump -r /tmp/capture.mitm -s filter_script_hex.py
mitmweb -r /tmp/capture.mitm

Typical short workflow
Start mitmdump with script.
Set macOS proxy to 127.0.0.1:8080.
Install & trust cert if you need HTTPS bodies.
Exercise the app/site.
Inspect terminal output (or saved .mitm file).
Stop, revert proxy, remove cert.
Short tips / gotchas
Some apps ignore system proxy or use certificate pinning — you won't see/decrypt those without extra work.
Hex-dumping big binaries is noisy — prefer file output for large bodies.
Remember to untrust the mitm CA and turn off proxy when done.
If you want, I can:
produce a slightly more compact filter_script_hex.py (single file you can drop in and run), or
add a tiny helper script to toggle macOS proxy and auto-run mitmdump.

