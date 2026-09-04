#!/usr/bin/env python3
"""
Sentinal Copier relay and control panel.

Two jobs:

  1. Relay      the master's snapshot to slaves on other machines.
  2. Control    show every slave in a web page and let you pause or resize one
                without touching MT5.

The EAs still do all the trading. This process never sees an account password,
holds no history, and cannot place a trade - it passes messages and remembers
the newest state of each participant in memory.

    python3 copier_relay.py --key A-LONG-SHARED-SECRET --port 8787

Then open http://<host>:8787/ and paste the same key.

Endpoints
    POST /publish?channel=NAME    master  -> relay   snapshot
    GET  /feed?channel=NAME       relay   -> slave   snapshot
    POST /status                  slave   -> relay   heartbeat + counters
    GET  /control?account=N       relay   -> slave   pause / sizing overrides
    POST /api/control?account=N   panel   -> relay   set those
    GET  /api/state               panel   <- relay   everything, as JSON
    GET  /                        the panel itself
    GET  /health                  liveness
"""

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

MAX_BODY = 1_048_576
STALE_CHANNEL = 300       # forget a channel nobody published to in 5 min
STALE_SLAVE = 120         # a slave silent this long is shown as offline

_lock = threading.Lock()
_channels = {}            # channel -> (payload bytes, wall time)
_slaves = {}              # account -> dict of reported fields + "seen"
_control = {}             # account -> {"paused", "multiplier", "maxlot"}
_key = ""


def _now():
    return time.time()


def _prune(now):
    for name in [n for n, (_, ts) in _channels.items() if now - ts > STALE_CHANNEL]:
        del _channels[name]


def _parse_kv(raw):
    """Parse the EAs' key=value line format. Values never contain newlines."""
    out = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


def _control_for(account):
    return _control.get(account, {"paused": 0, "multiplier": 0.0, "maxlot": 0.0})


PANEL_HTML = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sentinal Copier</title>
<style>
:root{--bg:#0d0f14;--card:#161a22;--line:#2a3240;--text:#e8ecf3;--dim:#8b95a7;
      --ok:#33d17a;--warn:#f0b429;--bad:#ff5c5c;--accent:#4a9eff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
     font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:20px 16px 60px}
h1{font-size:20px;margin:0 0 2px}
.sub{color:var(--dim);font-size:13px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
      padding:14px 16px;margin-bottom:12px}
.card h2{font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--dim);
         margin:0 0 10px;font-weight:700}
.row{display:flex;justify-content:space-between;gap:12px;padding:6px 0;
     border-bottom:1px solid var(--line);font-size:13px}
.row:last-child{border-bottom:0}
.row .k{color:var(--dim)}
.v{font-variant-numeric:tabular-nums;font-weight:600}
.good{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.7px;
   color:var(--dim);padding:6px 8px;border-bottom:1px solid var(--line);font-weight:700}
td{padding:9px 8px;border-bottom:1px solid var(--line);font-size:13px;
   font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:0}
input{background:#1e2430;border:1px solid var(--line);color:var(--text);
      border-radius:7px;padding:7px 9px;font:inherit;width:88px}
button{background:var(--accent);color:#fff;border:0;border-radius:7px;
       padding:7px 12px;font:inherit;font-weight:600;cursor:pointer}
button.ghost{background:#1e2430;border:1px solid var(--line);color:var(--text)}
button.danger{background:var(--bad)}
#gate{max-width:380px;margin:80px auto}
.hint{color:var(--dim);font-size:12px;margin-top:10px;line-height:1.5}
.hidden{display:none}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11px;font-weight:700}
.pill.ok{background:rgba(51,209,122,.15);color:var(--ok)}
.pill.warn{background:rgba(240,180,41,.15);color:var(--warn)}
.pill.bad{background:rgba(255,92,92,.15);color:var(--bad)}
</style>

<div class="wrap">
  <div id="gate" class="card">
    <h2>Sentinal Copier</h2>
    <p class="sub">Enter the relay key to view the panel.</p>
    <input id="key" type="password" placeholder="relay key" style="width:100%">
    <button id="go" style="width:100%;margin-top:10px">Open panel</button>
    <div class="hint">The same string the EAs use as <b>InpRelayKey</b>.
      Stored in this browser only.</div>
  </div>

  <div id="app" class="hidden">
    <h1>Sentinal Copier</h1>
    <div class="sub" id="stamp">…</div>

    <div class="card">
      <h2>Master</h2>
      <div id="master"></div>
    </div>

    <div class="card">
      <h2>Slaves</h2>
      <table>
        <thead><tr>
          <th>Account</th><th>Broker</th><th>State</th><th>Balance</th>
          <th>Copies</th><th>Last lot</th><th>Errors</th>
          <th>Multiplier</th><th>Max lot</th><th></th>
        </tr></thead>
        <tbody id="slaves"></tbody>
      </table>
      <div class="hint" id="empty">No slave has reported yet. A slave appears here
        once its EA is running with a panel URL and key set.</div>
    </div>
  </div>
</div>

<script>
const $ = s => document.querySelector(s);
let KEY = localStorage.getItem("copier.key") || "";

function headers(){ return {"X-Copier-Key": KEY, "Content-Type":"application/json"}; }

async function load(){
  try{
    const r = await fetch("/api/state", {headers: headers()});
    if(r.status === 401){ gate("Key rejected."); return; }
    render(await r.json());
  }catch(e){ $("#stamp").textContent = "relay unreachable"; }
}

function gate(msg){
  $("#app").classList.add("hidden");
  $("#gate").classList.remove("hidden");
  if(msg) $("#gate .hint").textContent = msg;
}

function fmt(n, d=2){ return (n===undefined||n===null||n==="") ? "—" : Number(n).toFixed(d); }

// Master lot beside the lot this slave actually got on. Matching numbers
// are the quickest confirmation that sizing is doing what was asked; a
// mismatch is flagged and the broker limit behind it sits in the tooltip.
function lots(v){
  const m = Number(v.lastmlot), s = Number(v.lastslot);
  if(!s) return "—";
  const same = Math.abs(m - s) < 0.005;
  return `${m.toFixed(2)} → ${s.toFixed(2)}` + (same ? "" : " ⚠");
}

function render(s){
  $("#gate").classList.add("hidden");
  $("#app").classList.remove("hidden");
  $("#stamp").textContent = "updated " + new Date().toLocaleTimeString();

  const m = s.master;
  $("#master").innerHTML = m
    ? `<div class="row"><span class="k">Channel</span><span class="v">${m.channel}</span></div>
       <div class="row"><span class="k">Age</span><span class="v ${m.age>30?'bad':'good'}">${m.age}s</span></div>
       <div class="row"><span class="k">Size</span><span class="v">${m.bytes} bytes</span></div>`
    : `<div class="row"><span class="k">Status</span><span class="v bad">no master publishing</span></div>`;

  const rows = s.slaves.map(v => {
    const off = v.age > 120;
    const cls = off ? "bad" : (v.paused ? "warn" : "ok");
    const label = off ? "OFFLINE" : (v.paused ? "PAUSED" : (v.state || "—"));
    return `<tr>
      <td>${v.account}</td>
      <td>${v.broker || "—"}</td>
      <td><span class="pill ${cls}">${label}</span></td>
      <td>${fmt(v.balance)}</td>
      <td>${v.copies ?? "—"}</td>
      <td class="${v.lotnote ? 'warn' : ''}" title="${v.lotnote || v.lotmode || ''}">${lots(v)}</td>
      <td class="${(v.errors|0)>0?'bad':''}">${v.errors ?? 0}</td>
      <td><input id="mul-${v.account}" value="${v.multiplier || ""}" placeholder="auto"></td>
      <td><input id="max-${v.account}" value="${v.maxlot || ""}" placeholder="none"></td>
      <td>
        <button class="ghost" onclick="save('${v.account}')">Save</button>
        <button class="${v.paused?'':'danger'}" onclick="pause('${v.account}',${v.paused?0:1})">
          ${v.paused ? "Resume" : "Pause"}</button>
      </td></tr>`;
  }).join("");

  $("#slaves").innerHTML = rows;
  $("#empty").style.display = s.slaves.length ? "none" : "block";
}

async function send(account, body){
  await fetch("/api/control?account=" + encodeURIComponent(account),
              {method:"POST", headers: headers(), body: JSON.stringify(body)});
  load();
}
function save(a){
  send(a, {multiplier: parseFloat($("#mul-"+a).value) || 0,
           maxlot:     parseFloat($("#max-"+a).value) || 0});
}
function pause(a, p){ send(a, {paused: p}); }

$("#go").onclick = () => {
  KEY = $("#key").value.trim();
  localStorage.setItem("copier.key", KEY);
  load();
};

if(KEY){ load(); } else { gate(); }
setInterval(() => { if(KEY && !$("#app").classList.contains("hidden")) load(); }, 2000);
</script>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SentinalCopierRelay/2.0"

    # --- helpers -----------------------------------------------------
    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _authorised(self):
        supplied = self.headers.get("X-Copier-Key", "")
        if len(supplied) != len(_key):
            return False
        return sum(a != b for a, b in zip(supplied, _key)) == 0

    def _q(self, name, maxlen=64):
        v = (parse_qs(urlparse(self.path).query).get(name) or [""])[0].strip()
        if not v or len(v) > maxlen or not all(c.isalnum() or c in "-_" for c in v):
            return None
        return v

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if n <= 0 or n > MAX_BODY:
            return None
        return self.rfile.read(n)

    # --- GET ---------------------------------------------------------
    def do_GET(self):
        route = urlparse(self.path).path

        if route == "/":
            self._send(200, PANEL_HTML, "text/html; charset=utf-8")
            return

        if route == "/health":
            with _lock:
                self._send(200, f"ok {len(_channels)} channel(s) "
                                f"{len(_slaves)} slave(s)\n")
            return

        if not self._authorised():
            self._send(401, b"bad key\n")
            return

        if route == "/feed":
            name = self._q("channel")
            if name is None:
                self._send(400, b"bad channel\n"); return
            with _lock:
                entry = _channels.get(name)
            if entry is None:
                self._send(404, b"no such channel\n"); return
            self._send(200, entry[0])
            return

        if route == "/control":
            acct = self._q("account")
            if acct is None:
                self._send(400, b"bad account\n"); return
            with _lock:
                c = _control_for(acct)
            self._send(200, "paused={}\nmultiplier={}\nmaxlot={}\n".format(
                int(c["paused"]), c["multiplier"], c["maxlot"]))
            return

        if route == "/api/state":
            now = _now()
            with _lock:
                master = None
                if _channels:
                    name, (payload, ts) = next(iter(_channels.items()))
                    master = {"channel": name, "age": int(now - ts),
                              "bytes": len(payload)}
                slaves = []
                for acct, s in sorted(_slaves.items()):
                    c = _control_for(acct)
                    slaves.append({
                        "account": acct,
                        "broker": s.get("broker", ""),
                        "state": s.get("state", ""),
                        "balance": s.get("balance", ""),
                        "copies": s.get("copies", ""),
                        "errors": s.get("errors", "0"),
                        "lotmode": s.get("lotmode", ""),
                        "lastmlot": s.get("lastmlot", ""),
                        "lastslot": s.get("lastslot", ""),
                        "lotnote": s.get("lotnote", ""),
                        "age": int(now - s.get("seen", 0)),
                        "paused": int(c["paused"]),
                        "multiplier": c["multiplier"] or "",
                        "maxlot": c["maxlot"] or "",
                    })
            self._send(200, json.dumps({"master": master, "slaves": slaves}),
                       "application/json")
            return

        self._send(404, b"not found\n")

    # --- POST --------------------------------------------------------
    def do_POST(self):
        route = urlparse(self.path).path

        if not self._authorised():
            self._send(401, b"bad key\n")
            return

        if route == "/publish":
            name = self._q("channel")
            body = self._body()
            if name is None or body is None:
                self._send(400, b"bad request\n"); return
            now = _now()
            with _lock:
                _channels[name] = (body, now)
                _prune(now)
            self._send(200, b"ok\n")
            return

        if route == "/status":
            body = self._body()
            if body is None:
                self._send(400, b"bad body\n"); return
            fields = _parse_kv(body.decode("utf-8", "replace"))
            acct = fields.get("account", "").strip()
            if not acct or not acct.isalnum():
                self._send(400, b"bad account\n"); return
            fields["seen"] = _now()
            with _lock:
                _slaves[acct] = fields
                # Hand the current control back in the same round trip, so a
                # slave needs one request per cycle rather than two.
                c = _control_for(acct)
            self._send(200, "paused={}\nmultiplier={}\nmaxlot={}\n".format(
                int(c["paused"]), c["multiplier"], c["maxlot"]))
            return

        if route == "/api/control":
            acct = self._q("account")
            body = self._body()
            if acct is None or body is None:
                self._send(400, b"bad request\n"); return
            try:
                req = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._send(400, b"bad json\n"); return

            with _lock:
                c = dict(_control_for(acct))
                if "paused" in req:
                    c["paused"] = 1 if req["paused"] else 0
                if "multiplier" in req:
                    c["multiplier"] = max(0.0, float(req["multiplier"] or 0))
                if "maxlot" in req:
                    c["maxlot"] = max(0.0, float(req["maxlot"] or 0))
                _control[acct] = c
            self._send(200, b"ok\n")
            return

        self._send(404, b"not found\n")

    def log_message(self, fmt, *args):
        pass


def main():
    global _key
    ap = argparse.ArgumentParser(description="Sentinal Copier relay and panel")
    ap.add_argument("--key", required=True,
                    help="shared secret; matches InpRelayKey in the EAs")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    if len(args.key) < 16:
        raise SystemExit("Use a key of at least 16 characters - it is the only "
                         "thing standing between your feed and the open internet.")
    _key = args.key

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"Sentinal Copier relay on {args.host}:{args.port}")
    print(f"Panel: http://<this-host>:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
