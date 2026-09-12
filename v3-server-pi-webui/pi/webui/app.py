import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import psutil
from flask import Flask, jsonify, redirect, render_template, request, url_for

from probe import probe_source
from vwcommon import install_basic_auth, parse_env_file

app = Flask(__name__)

ETC = Path("/etc/videowall")
PI_ENV = ETC / "pi.env"
SUDO = "/usr/bin/sudo"
PKILL = "/usr/bin/pkill"

# The Pi 4 has exactly two HDMI outputs, each its own X screen.
OUTPUTS = {
    "1": {"label": "Output 1 — HDMI0 (screen :0.0)", "key": "OUTPUT1_WALL"},
    "2": {"label": "Output 2 — HDMI1 (screen :0.1)", "key": "OUTPUT2_WALL"},
}

WALL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

install_basic_auth(app, ETC / "webui.env", "Video Wall Pi Admin")


# ---------- config ----------

PI_ENV_TEMPLATE = """# Raspberry Pi display client settings.
# Rewritten by the videowall Pi web UI on every save.

SERVER_HOST={server_host}
MEDIAMTX_SRT_PORT={mediamtx_srt_port}

OUTPUT1_WALL={output1_wall}
OUTPUT2_WALL={output2_wall}

SERVER_API_TOKEN={server_api_token}

SRT_LATENCY_MS={srt_latency_ms}
HWDEC={hwdec}
"""


def write_pi_env(data):
    PI_ENV.write_text(PI_ENV_TEMPLATE.format(**data))


def stream_url(env, wall):
    host = env.get("SERVER_HOST", "")
    port = env.get("MEDIAMTX_SRT_PORT", "8890")
    lat = env.get("SRT_LATENCY_MS", "400")
    return f"srt://{host}:{port}?streamid=read:{wall}&latency={lat}"


# ---------- display status ----------

HEALTH_FILE = Path("/run/videowall/health.json")
# Health older than this means the watchdog isn't running (or is wedged), so
# the numbers in the file are history, not status.
HEALTH_STALE_AFTER_S = 60


def read_health():
    """Stream health published by the watchdog.

    The watchdog runs in the display session (user videowall) and owns the mpv
    IPC sockets; this app runs as videowall-web and just reads its output. That
    avoids giving the web UI access to mpv's control socket, which would let a
    web request drive the player.
    """
    try:
        data = json.loads(HEALTH_FILE.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or "outputs" not in data:
        return None
    data["age_s"] = round(time.time() - float(data.get("updated", 0)), 1)
    data["stale"] = data["age_s"] > HEALTH_STALE_AFTER_S
    return data


def mpv_running_for(wall):
    """True if an mpv process is currently pulling this wall.

    Kept as a fallback for when the watchdog is disabled or its health file is
    missing. On its own this only proves a process exists — it stays true for
    a stream that froze hours ago, which is exactly why the watchdog exists.
    """
    if not wall:
        return False
    needle = f"streamid=read:{wall}"
    for proc in psutil.process_iter(["name", "cmdline"]):
        try:
            if proc.info["name"] != "mpv":
                continue
            if any(needle in arg for arg in (proc.info["cmdline"] or [])):
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return False


def restart_displays():
    """Kill the mpv processes; the xinitrc loops relaunch them within ~2s,
    re-reading pi.env, so new config applies without an X restart."""
    subprocess.run([SUDO, PKILL, "-x", "-u", "videowall", "mpv"],
                   check=False, timeout=10)


def pi_stats():
    stats = {
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "mem_percent": psutil.virtual_memory().percent,
        "load_avg": os.getloadavg(),
        "uptime_s": time.time() - psutil.boot_time(),
        "temp_c": None,
    }
    try:
        raw = Path("/sys/class/thermal/thermal_zone0/temp").read_text().strip()
        stats["temp_c"] = round(int(raw) / 1000, 1)
    except (OSError, ValueError):
        pass
    return stats


def server_walls(env):
    """Ask the server which walls exist, for the output pickers.

    Uses the read-only API token, never admin credentials. Returns None when
    the server can't be reached, so the UI falls back to manual entry rather
    than pretending there are no walls.
    """
    host = env.get("SERVER_HOST", "")
    token = env.get("SERVER_API_TOKEN", "")
    if not host or not token:
        return None
    req = urllib.request.Request(
        f"http://{host}:8080/api/walls",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            return json.loads(resp.read().decode("utf-8")).get("walls", [])
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return None


# ---------- routes ----------

@app.route("/")
def dashboard():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    env = parse_env_file(PI_ENV)
    health = read_health()
    hout = (health or {}).get("outputs", {})
    watchdog_live = bool(health) and not health.get("stale")

    outputs = []
    for key, meta in OUTPUTS.items():
        wall = env.get(meta["key"], "")
        entry = {
            "output": key,
            "label": meta["label"],
            "wall": wall,
            "displaying": mpv_running_for(wall),
        }
        h = hout.get(key) if watchdog_live else None
        if h:
            # Real stream health, measured over mpv's IPC socket.
            entry.update({
                "state": h.get("state"),
                "time_pos": h.get("time_pos"),
                "rate": h.get("rate"),
                "reconnects": h.get("reconnects"),
                "last_reason": h.get("last_reason"),
                "strikes": h.get("strikes"),
            })
        else:
            # Fall back to process existence, and say so rather than dressing
            # it up as stream health.
            entry["state"] = "unmonitored"
        outputs.append(entry)

    return jsonify({
        "pi": pi_stats(),
        "server_host": env.get("SERVER_HOST", ""),
        "srt_port": env.get("MEDIAMTX_SRT_PORT", "8890"),
        "watchdog": {
            "live": watchdog_live,
            "age_s": (health or {}).get("age_s"),
        },
        "outputs": outputs,
    })


@app.route("/api/walls")
def api_walls():
    """Proxy the server's wall list to the browser for the picker."""
    walls = server_walls(parse_env_file(PI_ENV))
    if walls is None:
        return jsonify({"walls": None,
                        "error": "Could not reach the server's API — check "
                                 "SERVER_HOST and the API token, or enter a "
                                 "wall name by hand."})
    return jsonify({"walls": walls})


@app.route("/api/test", methods=["POST"])
def api_test():
    """Probe a source: reachable, and is a stream really being published.

    With the relay in place there is no single-connection limit any more, so
    this is safe to run even while a wall is being displayed — the probe is
    simply one more reader.
    """
    body = request.get_json(silent=True) or {}
    env = parse_env_file(PI_ENV)
    raw_url = (body.get("url") or "").strip()
    wall = (body.get("wall") or "").strip()

    if wall:
        if not WALL_RE.match(wall):
            return jsonify({"accessible": False, "stream_detected": False,
                            "error": "Invalid wall name."}), 400
        if not env.get("SERVER_HOST"):
            return jsonify({"accessible": False, "stream_detected": False,
                            "error": "Set the server host first."}), 400
        url = stream_url(env, wall)
    elif raw_url:
        if not re.match(r"^(srt|rtsp|rtsps|udp|http|https)://", raw_url):
            return jsonify({"accessible": False, "stream_detected": False,
                            "error": "URL must start with srt://, rtsp://, "
                                     "udp:// or http(s)://"}), 400
        url = raw_url
    else:
        return jsonify({"error": "Provide either a wall name or a URL."}), 400

    result = probe_source(url, timeout_s=8,
                          rtsp_transport=env.get("RTSP_TRANSPORT", "tcp"))
    result["tested"] = re.sub(r"streamid=read:", "", url)
    return jsonify(result)


def save_config(form):
    errors = []
    server_host = form.get("server_host", "").strip()
    if not server_host:
        errors.append("Server host is required.")
    try:
        srt_port = int(form.get("mediamtx_srt_port", ""))
        srt_latency_ms = int(form.get("srt_latency_ms", ""))
    except ValueError:
        return ["Relay SRT port and latency must be whole numbers."]
    if not (1 <= srt_port <= 65535):
        errors.append("Relay SRT port must be between 1 and 65535.")
    if srt_latency_ms < 0:
        errors.append("SRT latency must be non-negative.")

    walls = {}
    for key, meta in OUTPUTS.items():
        val = (form.get(f"output{key}_wall") or "").strip()
        if val and not WALL_RE.match(val):
            errors.append(f"{meta['label']}: '{val}' is not a valid wall name.")
        walls[key] = val

    hwdec = form.get("hwdec", "v4l2m2m-copy").strip()
    if hwdec not in ("v4l2m2m-copy", "v4l2m2m", "auto", "no"):
        errors.append("HWDEC must be one of: v4l2m2m-copy, v4l2m2m, auto, no.")

    if errors:
        return errors

    write_pi_env({
        "server_host": server_host,
        "mediamtx_srt_port": srt_port,
        "output1_wall": walls["1"],
        "output2_wall": walls["2"],
        "server_api_token": form.get("server_api_token", "").strip(),
        "srt_latency_ms": srt_latency_ms,
        "hwdec": hwdec,
    })
    return []


@app.route("/config", methods=["GET", "POST"])
def config():
    errors = []
    if request.method == "POST":
        errors = save_config(request.form)
        if not errors:
            if request.form.get("action") == "save_apply":
                restart_displays()
                return redirect(url_for("config", saved="apply"))
            return redirect(url_for("config", saved="save"))

    return render_template(
        "config.html",
        env=parse_env_file(PI_ENV),
        outputs=OUTPUTS,
        errors=errors,
        saved=request.args.get("saved"),
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
