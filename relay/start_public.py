#!/usr/bin/env python3
"""
Start the Sentinal Copier relay and expose it on a public HTTPS address.

Use this when the master and the slaves are on different PCs on different
networks - a LAN address cannot reach them, and forwarding a router port is
both fiddly and worse for security.

It runs the relay locally, opens a Cloudflare quick tunnel in front of it, and
prints the public URL together with the exact values to paste into every MT5.

    python3 start_public.py

Needs cloudflared, which is a single executable and needs no account:
    Windows  https://github.com/cloudflare/cloudflared/releases/latest
             download cloudflared-windows-amd64.exe, rename it to
             cloudflared.exe and put it next to this script
    macOS    brew install cloudflared
    Linux    see the releases page above

One caveat worth knowing before you build a routine around it: a quick tunnel
gets a NEW address every time it starts, and MT5 only allows URLs you have
whitelisted. Restarting means re-whitelisting in every terminal. For anything
you intend to leave running, put the relay on a VPS with a fixed address
instead and point everything at that once.
"""

import collections
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(HERE, "copier_relay.py")
KEYFILE = os.path.join(HERE, "relay_key.txt")
PORT = 8787

URL_RE = re.compile(r"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com")

# Cloudflare's own service hosts sit on the same domain and turn up inside
# cloudflared's ERROR messages, so a bare pattern match will cheerfully hand
# back api.trycloudflare.com from a line saying the tunnel could not be opened.
NOT_A_TUNNEL = {"api.trycloudflare.com", "www.trycloudflare.com"}


def is_our_relay(url, timeout=4):
    """Confirm the address actually reaches the relay we just started.

    The regex alone cannot tell a working tunnel from a hostname quoted in an
    error, and printing the wrong URL sends someone off whitelisting an address
    that will never answer. /health needs no key and answers 'ok ...'.
    """
    try:
        with urllib.request.urlopen(url + "/health", timeout=timeout) as r:
            return r.read(64).lstrip().startswith(b"ok")
    except Exception:
        return False


def drain(proc, keep=15, on_line=None):
    """Read a child's output so its pipe never fills, keeping the last lines.

    Nothing reads these while things are healthy, but when a process dies at
    3am its last words are the whole diagnosis, so hold on to them.
    """
    tail = collections.deque(maxlen=keep)

    def pump():
        for line in proc.stdout:
            tail.append(line.rstrip())
            if on_line:
                on_line(line)

    threading.Thread(target=pump, daemon=True).start()
    return tail


def show_tail(what, tail):
    if tail:
        print(f"  Last output from {what}:")
        for line in tail:
            print(f"    {line}")


def report(what, tail):
    print(f"  The {what} stopped unexpectedly.")
    show_tail(what, tail)


def find_cloudflared():
    local = os.path.join(HERE, "cloudflared.exe" if os.name == "nt" else "cloudflared")
    if os.path.isfile(local):
        return local
    return shutil.which("cloudflared")


def load_key():
    if os.path.isfile(KEYFILE):
        key = open(KEYFILE).read().strip()
        if len(key) >= 16:
            return key
    key = secrets.token_urlsafe(24)
    with open(KEYFILE, "w") as f:
        f.write(key)
    print(f"  A new relay key was generated and saved in {KEYFILE}\n")
    return key


def banner(url, key):
    print()
    print("  " + "=" * 62)
    print("   Sentinal Copier - public relay is up")
    print("  " + "=" * 62)
    print()
    print(f"   Control panel:  {url}/")
    print(f"   Relay key:      {key}")
    print()
    print("   Paste into the MASTER and EVERY SLAVE:")
    print()
    print("     InpTransport = TRANSPORT_HTTP")
    print(f"     InpRelayUrl  = {url}")
    print(f"     InpRelayKey  = {key}")
    print()
    print("   Then in EACH terminal:")
    print("     Tools > Options > Expert Advisors")
    print("     tick  'Allow WebRequest for listed URL'")
    print(f"     add   {url}")
    print()
    print("   Leave this window open. Closing it takes the relay down.")
    print("  " + "=" * 62)
    print()


def main():
    if not os.path.isfile(RELAY):
        sys.exit(f"copier_relay.py not found next to this script ({HERE}).")

    cf = find_cloudflared()
    if not cf:
        print()
        print("  cloudflared was not found.")
        print()
        print("  It is one file and needs no account:")
        print("    https://github.com/cloudflare/cloudflared/releases/latest")
        print()
        print("  On Windows download cloudflared-windows-amd64.exe, rename it to")
        print("  cloudflared.exe, and put it in this same folder. Then run this again.")
        print()
        sys.exit(1)

    key = load_key()

    relay = subprocess.Popen(
        [sys.executable, RELAY, "--key", key, "--port", str(PORT)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    relay_tail = drain(relay)

    time.sleep(1.5)
    if relay.poll() is not None:
        report("relay", relay_tail)
        sys.exit(f"The relay failed to start. Port {PORT} already in use is the "
                 "usual reason - close the other relay window and try again.")

    print("  Relay running locally. Opening the tunnel...")

    tunnel = subprocess.Popen(
        [cf, "tunnel", "--url", f"http://localhost:{PORT}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )

    url = None

    def catch_url(line):
        # cloudflared prints its address once, mixed into ordinary log noise.
        nonlocal url
        if url is None:
            m = URL_RE.search(line)
            if m and m.group(0).split("//", 1)[1] not in NOT_A_TUNNEL:
                url = m.group(0)

    tunnel_tail = drain(tunnel, on_line=catch_url)

    deadline = time.time() + 45
    while url is None and time.time() < deadline and tunnel.poll() is None:
        time.sleep(0.25)

    if url is None:
        report("tunnel", tunnel_tail)
        tunnel.terminate()
        relay.terminate()
        sys.exit("The tunnel did not report an address. Check your internet "
                 "connection and try again.")

    # A fresh tunnel takes a few seconds to become reachable from outside.
    print(f"  Tunnel says {url} - checking it answers...")
    live = False
    check_until = time.time() + 30
    while time.time() < check_until and tunnel.poll() is None:
        if is_our_relay(url):
            live = True
            break
        time.sleep(2)

    if not live:
        show_tail("tunnel", tunnel_tail)
        tunnel.terminate()
        relay.terminate()
        sys.exit(f"{url} did not answer, so it is not a working tunnel. "
                 "Run this again; if it keeps happening, cloudflared is being "
                 "blocked and the relay needs a VPS instead.")

    banner(url, key)

    try:
        while True:
            if relay.poll() is not None:
                report("relay", relay_tail)
                break
            if tunnel.poll() is not None:
                report("tunnel", tunnel_tail)
                print("  The public address is gone; run this again for a new one.")
                break
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  Stopping...")
    finally:
        for p in (tunnel, relay):
            try:
                p.terminate()
                p.wait(timeout=5)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass


if __name__ == "__main__":
    main()
