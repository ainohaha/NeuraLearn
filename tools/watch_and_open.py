#!/usr/bin/env python3
"""
Watches the local network for the SageOS control server to appear and
auto-opens its control page in your default browser. Keep this running
in a terminal during study sessions — each time the headset app
launches, Safari pops up with the laptop control page.

Usage:
  python3 tools/watch_and_open.py
"""

from __future__ import annotations

import re
import signal
import subprocess
import sys
import time

SERVICE = "_sageos._tcp"
POLL_SECONDS = 2.0


def _drain(cmd: list[str], timeout: float) -> str:
    """Run a streaming command for `timeout` seconds, return captured output."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    deadline = time.time() + timeout
    out: list[str] = []
    try:
        while time.time() < deadline and p.poll() is None:
            # readline is blocking; sleep briefly and use communicate at end.
            time.sleep(0.05)
        # Drain anything ready.
        if p.stdout is not None:
            p.stdout.flush()
    finally:
        try:
            p.send_signal(signal.SIGTERM)
            try:
                stdout, _ = p.communicate(timeout=0.8)
                if stdout:
                    out.append(stdout)
            except subprocess.TimeoutExpired:
                p.kill()
                stdout, _ = p.communicate()
                if stdout:
                    out.append(stdout)
        except Exception:
            pass
    return "".join(out)


def find_instances() -> set[tuple[str, str]]:
    """Return the set of (instance_name, domain) currently advertising SageOS."""
    out = _drain(["dns-sd", "-B", SERVICE, "local."], timeout=2.5)
    instances: set[tuple[str, str]] = set()
    for line in out.splitlines():
        # dns-sd browse lines look like:
        #   17:42:53.123  Add        2   4 local.    _sageos._tcp.   SageOS
        if " Add" not in line:
            continue
        parts = line.split()
        if len(parts) < 7:
            continue
        # parts[-1] is the instance name (may contain spaces; rejoin from idx 6 on)
        instance = " ".join(parts[6:])
        domain = parts[4]
        instances.add((instance, domain))
    return instances


def resolve(instance: str, domain: str) -> tuple[str | None, str | None]:
    """Resolve an instance to (host, port). Returns (None, None) on failure."""
    out = _drain(["dns-sd", "-L", instance, SERVICE, domain], timeout=2.5)
    m = re.search(r"can be reached at\s+(\S+):(\d+)", out)
    if not m:
        return None, None
    return m.group(1).rstrip("."), m.group(2)


def main() -> None:
    print(f"Watching for {SERVICE} on the local network. Ctrl-C to stop.")
    # instance_name → last URL we opened. We keep this even when the service
    # vanishes (participant takes the AVP off-head → app suspends → mDNS
    # stops broadcasting), so when it reappears with the SAME URL we do NOT
    # spawn a new Safari tab — the existing tab's JS just reconnects to
    # /state on its own. Only a CHANGED URL (DHCP renew, different subnet,
    # app restart on a different IP) triggers a fresh tab.
    opened: dict[str, str] = {}
    last_seen: set[str] = set()
    while True:
        try:
            found = find_instances()
        except FileNotFoundError:
            print("dns-sd not found — this script is macOS-only.", file=sys.stderr)
            sys.exit(1)

        current_names = {instance for instance, _ in found}

        for instance, domain in found:
            host, port = resolve(instance, domain)
            if not host or not port:
                if instance not in last_seen:
                    print(f"  ? {instance} appeared but didn't resolve, retrying…")
                continue
            url = f"http://{host}:{port}"
            prev = opened.get(instance)
            if prev == url:
                # Same headset, same URL — silent re-appearance after an
                # off-head pause. The existing tab is already on this URL
                # and its polling loop has been waiting; do nothing.
                if instance not in last_seen:
                    print(f"  ~ {instance} back online ({url})")
                continue
            # First sighting, or the URL changed.
            tag = "+" if prev is None else "↻"
            print(f"  {tag} {instance}  →  {url}")
            # Force Safari: macOS resolves .local hostnames to IPv6
            # link-local addresses over AWDL, which Safari handles
            # correctly. Chrome and Firefox can't reach those addresses
            # without an explicit zone ID, so they fail with
            # ERR_ADDRESS_UNREACHABLE on isolated Wi-Fi.
            subprocess.run(["open", "-a", "Safari", url], check=False)
            opened[instance] = url

        # Disappearances: note once. Don't drop from `opened` — we want to
        # recognize the same URL on next reappearance.
        gone = last_seen - current_names
        for instance in gone:
            print(f"  - {instance}  (offline — keeping tab; will reuse when it returns)")

        last_seen = current_names
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        sys.exit(0)
