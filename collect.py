#!/usr/bin/env python3
"""Battery history collector for the kov.battery-history panel.

Merges three local sources into one JSON timeline:
  * UPower's charge history (/var/lib/upower/history-charge-<id>.dat)
  * the system journal: boots, suspend/resume, lid open/close
  * the user journal: Omarchy shell idle cycles (screensaver, lock = display off)

Usage: collect.py [window_seconds]
"""

import bisect
import glob
import json
import os
import re
import subprocess
import sys
import time

UPOWER_DIR = "/var/lib/upower"
LOOKBACK_PAD = 2 * 86400  # read events before the window to know the starting state
MAX_WINDOW = 31 * 86400
GAP_SECONDS = 45 * 60     # sample gaps longer than this are not used for drain rates


def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return out.stdout
    except Exception:
        return ""


def battery_history_file():
    """The charge history UPower is actively writing for the laptop battery.

    UPower keys files by model/serial or, without them, the design capacity,
    so pick the most recently written file holding real charge states.
    """
    best, best_mtime = None, 0
    for path in glob.glob(os.path.join(UPOWER_DIR, "history-charge-*.dat")):
        try:
            st = os.stat(path)
            if st.st_mtime <= best_mtime or st.st_size < 200:
                continue
            with open(path, "r", errors="replace") as f:
                f.seek(max(0, st.st_size - 2000))
                tail = f.read()
            if "discharging" in tail or "charging" in tail:
                best, best_mtime = path, st.st_mtime
        except OSError:
            continue
    return best


def read_samples(path, since):
    samples = []
    if not path:
        return samples
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                try:
                    t = int(parts[0])
                    p = float(parts[1])
                except ValueError:
                    continue
                s = parts[2].strip()
                if s == "unknown" or not (0 <= p <= 100):
                    continue
                samples.append((t, p, s))
    except OSError:
        return []
    samples.sort(key=lambda x: x[0])
    # Keep one sample before the window so the line starts at the left edge.
    i = bisect.bisect_left([s[0] for s in samples], since)
    return samples[max(0, i - 1):]


def journal_lines(args, since):
    cmd = ["journalctl", "--no-pager", "-q", "-o", "short-unix", "--since", "@%d" % since] + args
    for line in run(cmd).splitlines():
        head, _, rest = line.partition(" ")
        try:
            yield float(head), rest
        except ValueError:
            continue


def boots():
    try:
        data = json.loads(run(["journalctl", "--list-boots", "-o", "json", "--no-pager"]) or "[]")
    except ValueError:
        return []
    out = []
    for b in data:
        try:
            out.append((b["first_entry"] / 1e6, b["last_entry"] / 1e6))
        except (KeyError, TypeError):
            continue
    out.sort()
    return out


class Steps:
    """A piecewise-constant signal: value(t) is the last value set at or before t."""

    def __init__(self, initial):
        self.times, self.values, self.initial = [], [], initial

    def set(self, t, v):
        self.times.append(t)
        self.values.append(v)

    def finish(self):
        order = sorted(range(len(self.times)), key=lambda i: self.times[i])
        self.times = [self.times[i] for i in order]
        self.values = [self.values[i] for i in order]

    def at(self, t):
        i = bisect.bisect_right(self.times, t) - 1
        return self.values[i] if i >= 0 else self.initial


def main():
    now = time.time()
    try:
        window = int(sys.argv[1]) if len(sys.argv) > 1 else 86400
    except ValueError:
        window = 86400
    window = max(3600, min(MAX_WINDOW, window))
    start = now - window
    since = start - LOOKBACK_PAD

    path = battery_history_file()
    samples = read_samples(path, start)

    # --- running: boot intervals --------------------------------------------
    running = Steps(False)
    boot_list = boots()
    for i, (b0, b1) in enumerate(boot_list):
        running.set(b0, True)
        if i == len(boot_list) - 1:
            b1 = now  # the current boot is still going
        running.set(b1, False)
    running.finish()

    # --- asleep: kernel suspend entry/exit ----------------------------------
    asleep = Steps(False)
    for t, msg in journal_lines(["_TRANSPORT=kernel", "-g", r"PM: suspend (entry|exit)"], since):
        asleep.set(t, "entry" in msg)
    asleep.finish()

    # --- hibernated: suspend-then-hibernate wakes at HibernateDelaySec, logs
    # "PM: suspend exit", then "hibernation entry" the same second; "exit"
    # comes after the image is restored, in the same boot.
    hibernating = Steps(False)
    for t, msg in journal_lines(["_TRANSPORT=kernel", "-g", r"PM: hibernation: hibernation (entry|exit)"], since):
        hibernating.set(t, "entry" in msg)
    hibernating.finish()

    # --- lid ----------------------------------------------------------------
    lid_closed = Steps(False)
    for t, msg in journal_lines(["-u", "systemd-logind", "-g", r"Lid (opened|closed)\."], since):
        lid_closed.set(t, "Lid closed" in msg)
    # A resume always comes with the lid open on this machine when it was the
    # lid that put it to sleep; logind logs that, so nothing else needed.
    lid_closed.finish()

    # --- idle: omarchy shell idle service -----------------------------------
    # active -> screensaver (idle-cycle-start) -> locked/display off
    # (lock-system) -> active (cancel, or input after the lock).
    idle = Steps("active")
    idle_events = list(journal_lines(
        ["--user", "-t", "omarchy-shell", "-g", r"omarchy idle "], since))
    rx = re.compile(r"omarchy idle \S+ (.*)$")
    parsed = []
    for t, msg in idle_events:
        m = rx.search(msg)
        if m:
            parsed.append((t, m.group(1)))
    state = "active"
    for i, (t, ev) in enumerate(parsed):
        if ev.startswith("idle-cycle-start"):
            state = "screensaver"
        elif ev.startswith("lock-system"):
            state = "locked" if state != "active" else state
        elif ev.startswith("idle-cycle-cancel") or ev.startswith("service-ready"):
            state = "active"
        elif ev.startswith("idle-monitor: active"):
            # The screensaver grabbing the pointer reports activity that is
            # immediately re-armed; that is not the user coming back.
            nxt = parsed[i + 1] if i + 1 < len(parsed) else None
            if nxt and nxt[1].startswith("idle-monitor-active") and nxt[0] - t < 2:
                continue
            state = "active"
        else:
            continue
        idle.set(t, state)
    # Waking from suspend or hibernation lands on the lock screen with the
    # display on.
    for sig in (asleep, hibernating):
        for t, v in zip(sig.times, sig.values):
            if not v:
                idle.set(t, "active")
    idle.finish()

    # --- screen timeline ----------------------------------------------------
    def screen_at(t):
        if not running.at(t):
            return "off"
        if hibernating.at(t):
            return "hibernate"
        if asleep.at(t):
            return "sleep"
        if lid_closed.at(t):
            return "lid"
        st = idle.at(t)
        if st == "locked":
            return "dark"
        if st == "screensaver":
            return "idle"
        return "on"

    bounds = {start, now}
    for sig in (running, asleep, hibernating, lid_closed, idle):
        for t in sig.times:
            if start < t < now:
                bounds.add(t)
    bounds = sorted(bounds)
    screen = []
    for a, b in zip(bounds, bounds[1:]):
        if b - a <= 0:
            continue
        cat = screen_at((a + b) / 2)
        if screen and screen[-1][2] == cat:
            screen[-1][1] = b
        else:
            screen.append([a, b, cat])

    # --- power timeline (from UPower states) --------------------------------
    def power_cat(s):
        if s == "charging":
            return "charging"
        if s in ("fully-charged", "pending-charge"):
            return "plugged"
        return "battery"

    power = []
    for i, (t, p, s) in enumerate(samples):
        a = max(start, t)
        b = samples[i + 1][0] if i + 1 < len(samples) else now
        b = min(now, b)
        if b <= a:
            continue
        cat = power_cat(s)
        if power and power[-1][2] == cat and abs(power[-1][1] - a) < 1:
            power[-1][1] = b
        else:
            power.append([a, b, cat])

    # --- stats --------------------------------------------------------------
    def overlap(a, b, segs):
        out = {}
        for s0, s1, c in segs:
            lo, hi = max(a, s0), min(b, s1)
            if hi > lo:
                out[c] = out.get(c, 0) + (hi - lo)
        return out

    totals = overlap(start, now, screen)
    ptotals = overlap(start, now, power)

    # Spread each discharging step's drop over the screen states it spanned.
    drop = {}
    on_batt_time = {}
    for (t0, p0, s0), (t1, p1, s1) in zip(samples, samples[1:]):
        if s0 != "discharging" or s1 != "discharging":
            continue
        a, b = max(t0, start), min(t1, now)
        if b <= a or p1 > p0:
            continue
        span = t1 - t0
        parts = overlap(t0, t1, screen)
        asleep_part = parts.get("sleep", 0) + parts.get("hibernate", 0) + parts.get("off", 0)
        if span - asleep_part > GAP_SECONDS:
            continue
        frac_in_window = (b - a) / span if span else 0
        for c, secs in parts.items():
            share = secs / span if span else 0
            drop[c] = drop.get(c, 0) + (p0 - p1) * share * frac_in_window
            on_batt_time[c] = on_batt_time.get(c, 0) + secs * frac_in_window

    def rate(cats):
        d = sum(drop.get(c, 0) for c in cats)
        h = sum(on_batt_time.get(c, 0) for c in cats) / 3600
        return round(d / h, 2) if h > 0.25 else None

    total_drop = sum(drop.values())

    stats = {
        "screenOn": round(totals.get("on", 0) + totals.get("idle", 0)),
        "screenActive": round(totals.get("on", 0)),
        "displayOff": round(totals.get("dark", 0)),
        "lidClosed": round(totals.get("lid", 0)),
        "asleep": round(totals.get("sleep", 0)),
        "hibernated": round(totals.get("hibernate", 0)),
        "off": round(totals.get("off", 0)),
        "charging": round(ptotals.get("charging", 0)),
        "plugged": round(ptotals.get("charging", 0) + ptotals.get("plugged", 0)),
        "onBattery": round(ptotals.get("battery", 0)),
        "drainScreenOn": rate(["on", "idle"]),
        "drainAsleep": rate(["sleep"]),
        "drainAwakeDark": rate(["dark", "lid"]),
        "used": round(total_drop, 1),
    }

    out = {
        "now": now,
        "start": start,
        "window": window,
        "source": os.path.basename(path) if path else "",
        "samples": [[t, p, s] for t, p, s in samples],
        "screen": [[round(a, 1), round(b, 1), c] for a, b, c in screen],
        "power": [[round(a, 1), round(b, 1), c] for a, b, c in power],
        "stats": stats,
    }
    json.dump(out, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
