import os
import re
import time
import json
import subprocess
from pathlib import Path

from flask import Flask, request, render_template, redirect, url_for, jsonify, Response
from werkzeug.security import check_password_hash
import psutil

app = Flask(__name__)

ETC = Path("/etc/videowall")
PI_ENV = ETC / "pi.env"
SUDO = "/usr/bin/sudo"
PKILL = "/usr/bin/pkill"
FFPROBE = "/usr/bin/ffprobe"

# The two source streams this Pi displays, and which env key holds each port.
STREAMS = {
    "4k": {"label": "4K wall (screen :0.0)", "port_key": "PORT_4K", "default_port": 6000},
    "1080p": {"label": "1080p wall (screen :0.1)", "port_key": "PORT_1080P", "default_port": 6001},
}


# ---------- pi.env parsing / writing ----------

def parse_env_file(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip().strip('"').strip("'")
    return values


PI_ENV_TEMPLATE = """# Raspberry Pi display client settings.
# Rewritten by the videowall Pi web UI on every save. Each display loop in
# ~videowall/.xinitrc re-reads this file on every reconnect, so applying a
# change is just restarting the mpv processes (the web UI's "Apply" button).

SERVER_HOST={server_host}
PORT_4K={port_4k}
PORT_1080P={port_1080p}
SRT_LATENCY_MS={srt_latency_ms}
HWDEC={hwdec}
"""


def write_pi_env(data):
    PI_ENV.write_text(PI_ENV_TEMPLATE.format(**data))


def stream_url(cfg, host=None, port=None, latency=None, extra=""):
    env = parse_env_file(PI_ENV)
    host = host or env.get("SERVER_HOST", "")
    port = port or env.get(cfg["port_key"], cfg["default_port"])
    latency = latency or env.get("SRT_LATENCY_MS", "400")
    return f"srt://{host}:{port}?mode=caller&latency={latency}{extra}"


# ---------- display / process status ----------

def mpv_running_for(port):
    """True if an mpv process is currently launched against this SRT port —
    i.e. that screen is actively displaying (or trying to)."""
    needle = f":{port}?"
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
    re-reading pi.env, so new config takes effect without an X restart."""
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


# ---------- stream source test (the point of this UI) ----------

# ffprobe stderr fragments that mean "never even connected" (address/port not
# reachable) vs. "connected but couldn't find a stream".
_UNREACHABLE_HINTS = (
    "connection timed out", "no route to host", "connection refused",
    "network is unreachable", "timed out", "failed to connect",
    "temporary failure in name resolution", "name or service not known",
)


def probe_source(url, timeout_s=8):
    """Run ffprobe against a source URL and report (accessible, stream_detected,
    details/error). For SRT this performs the caller handshake (proving the
    address/port is reachable) and reads stream metadata (proving a stream is
    present) in one shot — see README for why a separate raw UDP port check
    isn't meaningful for SRT."""
    # SRT connect timeout is in microseconds; give ffprobe a bit less than our
    # own subprocess timeout so it returns its own error rather than being
    # hard-killed.
    if url.startswith("srt://"):
        sep = "&" if "?" in url else "?"
        probe_url = f"{url}{sep}timeout={int((timeout_s - 2) * 1_000_000)}"
    else:
        probe_url = url

    cmd = [
        FFPROBE, "-v", "error",
        "-print_format", "json",
        "-show_streams", "-show_format",
        probe_url,
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"accessible": False, "stream_detected": False,
                "error": f"No response within {timeout_s}s — address/port not reachable, "
                         "or nothing is publishing on it."}
    except FileNotFoundError:
        return {"accessible": None, "stream_detected": None,
                "error": "ffprobe not found on this Pi (install the ffmpeg package)."}

    stderr = (res.stderr or "").strip()
    if res.returncode == 0 and res.stdout.strip():
        try:
            data = json.loads(res.stdout)
        except json.JSONDecodeError:
            data = {}
        vstreams = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
        if vstreams:
            v = vstreams[0]
            fr = v.get("avg_frame_rate") or v.get("r_frame_rate") or "0/0"
            try:
                num, den = fr.split("/")
                fps = round(int(num) / int(den), 1) if int(den) else None
            except (ValueError, ZeroDivisionError):
                fps = None
            details = {
                "codec": v.get("codec_name"),
                "width": v.get("width"),
                "height": v.get("height"),
                "fps": fps,
                "bitrate_kbps": (int(data.get("format", {}).get("bit_rate", 0)) // 1000)
                                if data.get("format", {}).get("bit_rate") else None,
            }
            return {"accessible": True, "stream_detected": True, "details": details}
        # Connected, format read, but no video stream.
        return {"accessible": True, "stream_detected": False,
                "error": "Connected, but no video stream was found in the source."}

    low = stderr.lower()
    accessible = not any(h in low for h in _UNREACHABLE_HINTS)
    return {
        "accessible": accessible,
        "stream_detected": False,
        "error": stderr or "ffprobe failed with no error output.",
    }


# ---------- auth ----------

def check_auth(auth):
    creds = parse_env_file(ETC / "webui.env")
    expected_user = creds.get("WEBUI_USER", "")
    expected_hash = creds.get("WEBUI_PASSWORD_HASH", "")
    if not auth or not expected_hash or auth.username != expected_user:
        return False
    return check_password_hash(expected_hash, auth.password)


@app.before_request
def require_auth():
    if not check_auth(request.authorization):
        return Response(
            "Authentication required.", 401,
            {"WWW-Authenticate": 'Basic realm="Video Wall Pi Admin"'},
        )


# ---------- routes ----------

@app.route("/")
def dashboard():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    env = parse_env_file(PI_ENV)
    walls = []
    for key, cfg in STREAMS.items():
        port = env.get(cfg["port_key"], cfg["default_port"])
        walls.append({
            "key": key,
            "label": cfg["label"],
            "port": port,
            "displaying": mpv_running_for(port),
        })
    return jsonify({
        "pi": pi_stats(),
        "server_host": env.get("SERVER_HOST", ""),
        "walls": walls,
    })


@app.route("/api/test", methods=["POST"])
def api_test():
    body = request.get_json(silent=True) or {}
    key = body.get("stream")
    raw_url = (body.get("url") or "").strip()

    if key in STREAMS:
        cfg = STREAMS[key]
        env = parse_env_file(PI_ENV)
        port = env.get(cfg["port_key"], cfg["default_port"])
        # A live display already holds the server's single SRT listener slot;
        # a second caller would be refused, so don't probe — the active
        # display IS proof the source is reachable and streaming.
        if mpv_running_for(port):
            return jsonify({
                "accessible": True, "stream_detected": True,
                "note": "This wall is currently being displayed, which already "
                        "confirms the source is reachable and streaming. Stop the "
                        "display to run a full probe for codec/resolution details.",
            })
        url = stream_url(cfg, host=body.get("host") or None,
                         port=body.get("port") or None,
                         latency=body.get("latency") or None)
    elif raw_url:
        if not re.match(r"^(srt|rtsp|udp|http|https)://", raw_url):
            return jsonify({"accessible": False, "stream_detected": False,
                            "error": "URL must start with srt://, rtsp://, udp://, or http(s)://"}), 400
        url = raw_url
    else:
        return jsonify({"error": "Provide either a known 'stream' key or a 'url'."}), 400

    result = probe_source(url)
    result["tested_url"] = url
    return jsonify(result)


def save_config(form):
    server_host = form.get("server_host", "").strip()
    errors = []
    if not server_host:
        errors.append("Server host is required.")
    try:
        port_4k = int(form.get("port_4k", ""))
        port_1080p = int(form.get("port_1080p", ""))
        srt_latency_ms = int(form.get("srt_latency_ms", ""))
    except ValueError:
        return ["Ports and SRT latency must be whole numbers."]
    for label, p in (("PORT_4K", port_4k), ("PORT_1080P", port_1080p)):
        if not (1 <= p <= 65535):
            errors.append(f"{label} must be between 1 and 65535.")
    if srt_latency_ms < 0:
        errors.append("SRT latency must be non-negative.")
    hwdec = form.get("hwdec", "v4l2m2m-copy").strip()
    if hwdec not in ("v4l2m2m-copy", "v4l2m2m", "auto", "no"):
        errors.append("HWDEC must be one of: v4l2m2m-copy, v4l2m2m, auto, no.")

    if errors:
        return errors

    write_pi_env({
        "server_host": server_host,
        "port_4k": port_4k,
        "port_1080p": port_1080p,
        "srt_latency_ms": srt_latency_ms,
        "hwdec": hwdec,
    })
    return []


@app.route("/config", methods=["GET", "POST"])
def config():
    errors = []
    if request.method == "POST":
        action = request.form.get("action")
        errors = save_config(request.form)
        if not errors:
            if action == "save_apply":
                restart_displays()
                return redirect(url_for("config", saved="apply"))
            return redirect(url_for("config", saved="save"))

    return render_template(
        "config.html",
        env=parse_env_file(PI_ENV),
        streams=STREAMS,
        errors=errors,
        saved=request.args.get("saved"),
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
