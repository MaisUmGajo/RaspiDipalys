#!/usr/bin/env python3
"""Watch each display's mpv and reconnect streams that have silently failed.

The display loops in ~videowall/.xinitrc only react when mpv *exits*. That
misses the failure modes that matter most on a long-haul link: a stream that
freezes, one that degrades to a fraction of real time, or one that keeps
"playing" while the decoder produces a corrupt picture. In all three the
process is alive and the wall looks fine from the outside, so nothing ever
recovers it.

Detection logic and thresholds are ported from the displaycameras-modern
project (Apache License 2.0, Copyright 2026 Miguel Costa) — see NOTICE — where
they were tuned against real hardware. The implementation differs: this is a
long-lived process, so per-stream state lives in memory rather than in the
scratch files that project's shell loop needed.

Three detectors, in priority order:

  frozen    time-pos has stopped advancing entirely
  degraded  time-pos advances below STALL_RATE x real time
  corrupt   decoder drop count jumped by >= ERROR_RELOAD_THRESHOLD

Recovery is an mpv `loadfile` — a reconnect in place, with no black screen and
no process churn, which also forces a fresh keyframe.

It also publishes a health file the web UI reads, so the dashboard can report
what the stream is actually doing rather than "the process exists".
"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, "/opt/videowall/webui")  # where install.sh puts the shared helpers
from mpvipc import MpvIPC  # noqa: E402
from vwcommon import parse_env_file  # noqa: E402

PI_ENV = Path("/etc/videowall/pi.env")

# Screen :0.0 is HDMI0, :0.1 is HDMI1 — matching the display loops in .xinitrc.
OUTPUTS = {"1": "OUTPUT1_WALL", "2": "OUTPUT2_WALL"}

# Ignore samples shorter than this: over a second or two, normal jitter makes
# the measured rate meaningless.
MIN_SAMPLE_S = 5.0


def run_dir():
    d = Path("/run/videowall")
    try:
        d.mkdir(parents=True, exist_ok=True)
        if os.access(d, os.W_OK):
            return d
    except OSError:
        pass
    d = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "videowall"
    d.mkdir(parents=True, exist_ok=True)
    return d


RUN_DIR = run_dir()
HEALTH_FILE = RUN_DIR / "health.json"


def socket_for(output):
    return RUN_DIR / f"mpv-{output}.sock"


def stream_url(env, wall):
    host = env.get("SERVER_HOST", "")
    port = env.get("MEDIAMTX_SRT_PORT", "8890")
    latency = env.get("SRT_LATENCY_MS", "400")
    return f"srt://{host}:{port}?streamid=read:{wall}&latency={latency}"


def as_float(value, default):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


class OutputState:
    """Rolling measurement state for one display."""

    def __init__(self, output):
        self.output = output
        self.wall = ""
        self.prev_pos = None
        self.prev_clock = None
        self.prev_drops = None
        self.strikes = 0
        self.rate = None
        self.reconnects = 0
        self.last_reason = ""
        self.last_reconnect = None
        self.state = "unknown"
        self.time_pos = None
        self.drops = None

    def reset_baseline(self):
        """Forget measurements, e.g. after a reconnect or a wall change, so we
        do not immediately re-strike against pre-reconnect samples."""
        self.prev_pos = None
        self.prev_clock = None
        self.prev_drops = None
        self.strikes = 0
        self.rate = None

    def as_dict(self):
        return {
            "wall": self.wall,
            "state": self.state,
            "time_pos": round(self.time_pos, 1) if self.time_pos is not None else None,
            "rate": round(self.rate, 2) if self.rate is not None else None,
            "drops": self.drops,
            "strikes": self.strikes,
            "reconnects": self.reconnects,
            "last_reason": self.last_reason,
            "last_reconnect": self.last_reconnect,
        }


def check_output(st, env, cfg, now):
    """Update one output's state, reconnecting it if needed."""
    wall = env.get(cfg["wall_key"], "").strip()
    if wall != st.wall:
        st.wall = wall
        st.reset_baseline()

    if not wall:
        st.state = "no_wall"
        st.time_pos = st.drops = st.rate = None
        return

    mpv = MpvIPC(socket_for(st.output))
    if not mpv.responsive():
        # Either mpv has not started yet or it died and the display loop is
        # about to relaunch it. Relaunching is that loop's job, not ours.
        st.state = "starting"
        st.time_pos = st.drops = st.rate = None
        st.reset_baseline()
        return

    if mpv.get("idle-active") is True:
        st.state = "idle"
        st.reset_baseline()
        return

    st.time_pos = as_float(mpv.get("time-pos"), None)
    st.drops = mpv.get("decoder-frame-drop-count")
    reason = ""

    # (1) Decoder error burst: the picture is corrupt but frames keep coming,
    # so nothing else notices. A reconnect forces a clean keyframe.
    if cfg["error_threshold"] > 0 and isinstance(st.drops, int):
        if st.prev_drops is None or st.drops < st.prev_drops:
            st.prev_drops = st.drops          # first sample, or mpv restarted
        elif st.drops - st.prev_drops >= cfg["error_threshold"]:
            reason = f"decoder dropped {st.drops - st.prev_drops} frames"
        else:
            st.prev_drops = st.drops

    # (2) Frozen or degraded: compare playback advance against wall clock.
    if not reason and st.time_pos is not None and cfg["stall_rate"] > 0:
        if st.prev_pos is not None and st.prev_clock is not None:
            wall_delta = now - st.prev_clock
            pos_delta = st.time_pos - st.prev_pos
            if pos_delta < 0:
                st.reset_baseline()           # reconnect/seek: re-baseline
            elif wall_delta >= MIN_SAMPLE_S:
                st.rate = pos_delta / wall_delta
                if st.rate < cfg["stall_rate"]:
                    st.strikes += 1
                    # Require sustained slowness. A single dip on a congested
                    # link is normal; reconnecting on it would thrash, and a
                    # reconnect costs more than riding out a brief wobble.
                    if st.strikes >= cfg["stall_strikes"]:
                        kind = "frozen" if pos_delta == 0 else "degraded"
                        reason = (f"{kind}: {st.rate:.2f}x real time "
                                  f"over {st.strikes} checks")
                    else:
                        st.prev_pos, st.prev_clock = st.time_pos, now
                else:
                    st.strikes = 0
                    st.prev_pos, st.prev_clock = st.time_pos, now
        else:
            st.prev_pos, st.prev_clock = st.time_pos, now

    if reason:
        url = stream_url(env, wall)
        ok = mpv.loadfile(url)
        st.reconnects += 1
        st.last_reason = reason
        st.last_reconnect = now
        st.state = "reconnecting"
        st.reset_baseline()
        print(f"[watchdog] output {st.output} ({wall}): {reason} — "
              f"reconnect {'sent' if ok else 'FAILED'}", flush=True)
        return

    if st.strikes > 0:
        st.state = "degraded"
    elif st.time_pos is None:
        st.state = "no_timepos"
    else:
        st.state = "playing"


def write_health(states, now):
    """Publish health for the web UI, which runs as a different user and has
    no business talking to mpv's socket directly."""
    payload = {
        "updated": now,
        "outputs": {out: st.as_dict() for out, st in states.items()},
    }
    tmp = HEALTH_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(payload))
        os.chmod(tmp, 0o644)
        tmp.replace(HEALTH_FILE)   # atomic: the UI never sees a partial file
    except OSError as exc:
        print(f"[watchdog] could not write {HEALTH_FILE}: {exc}", flush=True)


def main():
    states = {out: OutputState(out) for out in OUTPUTS}
    print(f"[watchdog] started; health -> {HEALTH_FILE}", flush=True)

    while True:
        # Re-read config every cycle, like the display loops do, so changes
        # from the web UI take effect without restarting anything.
        env = parse_env_file(PI_ENV)
        interval = as_float(env.get("WATCHDOG_INTERVAL_S"), 15.0)
        if interval <= 0:
            # Disabled: keep publishing wall assignments so the UI still shows
            # something sensible, but do not measure or act.
            now = time.time()
            for out, key in OUTPUTS.items():
                states[out].wall = env.get(key, "").strip()
                states[out].state = "watchdog_disabled"
            write_health(states, now)
            time.sleep(15)
            continue

        cfg = {
            "stall_rate": as_float(env.get("STALL_RATE"), 0.5),
            "stall_strikes": max(1, as_int(env.get("STALL_STRIKES"), 2)),
            "error_threshold": as_int(env.get("ERROR_RELOAD_THRESHOLD"), 10),
        }
        now = time.time()
        for out, key in OUTPUTS.items():
            cfg["wall_key"] = key
            try:
                check_output(states[out], env, cfg, now)
            except Exception as exc:  # never let one bad output kill the loop
                states[out].state = "error"
                print(f"[watchdog] output {out} check failed: {exc}", flush=True)
        write_health(states, now)
        time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
