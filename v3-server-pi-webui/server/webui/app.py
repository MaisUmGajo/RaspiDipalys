import os
import time
import subprocess
from pathlib import Path

from flask import Flask, request, render_template, redirect, url_for, jsonify, Response
from werkzeug.security import check_password_hash
import psutil

app = Flask(__name__)

ETC = Path("/etc/videowall")
RUN = Path("/run/videowall")
SUDO = "/usr/bin/sudo"
SYSTEMCTL = "/usr/bin/systemctl"

WALLS = {
    "4k": {"label": "4K (3x3)", "service": "videowall-encode-4k.service"},
    "1080p": {"label": "1080p (2x2)", "service": "videowall-encode-1080p.service"},
}


# ---------- config file parsing / writing ----------

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


def read_wall_env(wall):
    return parse_env_file(ETC / f"wall-{wall}.env")


def read_global_env():
    return parse_env_file(ETC / "videowall-server.env")


def read_cameras(path_str):
    path = Path(path_str)
    if not path.exists():
        return []
    return [
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


WALL_ENV_TEMPLATE = """# Per-wall settings for the {label} mosaic.
# Rewritten by the videowall web UI on every save.

ROWS={rows}
COLS={cols}
CANVAS_W={canvas_w}
CANVAS_H={canvas_h}

PORT={port}

BITRATE_KBPS={bitrate_kbps}
FPS={fps}

CAMERAS_FILE={cameras_file}
"""


def write_wall_env(wall, data):
    content = WALL_ENV_TEMPLATE.format(label=WALLS[wall]["label"], **data)
    (ETC / f"wall-{wall}.env").write_text(content)


GLOBAL_ENV_TEMPLATE = """# Global settings, shared by both walls.
# Rewritten by the videowall web UI on every save.

RTSP_TRANSPORT={rtsp_transport}
SRT_LATENCY_MS={srt_latency_ms}
VAAPI={vaapi}
"""


def write_global_env(data):
    (ETC / "videowall-server.env").write_text(GLOBAL_ENV_TEMPLATE.format(**data))


def write_cameras(path_str, urls):
    header = f"# {len(urls)} RTSP URLs, one per line, row-major order.\n# Rewritten by the videowall web UI on every save.\n\n"
    body = "\n".join(urls) + ("\n" if urls else "")
    Path(path_str).write_text(header + body)


# ---------- systemd / progress-file status ----------

def restart_service(service):
    subprocess.run([SUDO, SYSTEMCTL, "restart", service], check=True, timeout=15)


def systemctl_show(service):
    try:
        out = subprocess.run(
            [SUDO, SYSTEMCTL, "show", service],
            check=True, capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return {}
    info = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            info[k] = v
    return info


def read_progress(wall):
    """Parse ffmpeg's -progress output file.

    ffmpeg appends repeated blocks of "key=value" lines, each terminated by
    a "progress=continue" (or "progress=end") line. We walk line by line,
    accumulating into `current` and flushing it into `last_complete`
    whenever we hit a "progress=" line — so a partial/torn last block (e.g.
    ffmpeg killed mid-write) is simply discarded rather than shown as if
    it were valid.
    """
    path = RUN / f"progress-{wall}.txt"
    if not path.exists():
        return None, None
    try:
        text = path.read_text()
        mtime = path.stat().st_mtime
    except OSError:
        return None, None

    last_complete = {}
    current = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if key == "progress":
            last_complete = current
            current = {}
        else:
            current[key] = value

    return (last_complete or None), mtime


def wall_status(wall):
    service = WALLS[wall]["service"]
    show = systemctl_show(service)
    progress, mtime = read_progress(wall)

    # SRT listener mode blocks ffmpeg's output-open until a client (the Pi)
    # connects, so a recently-updated progress file is a reasonable proxy
    # for "a client is currently connected and streaming". This does NOT
    # give per-client detail (IP, RTT, loss %) — ffmpeg doesn't expose
    # that; only connected/not-connected.
    connected = mtime is not None and (time.time() - mtime) < 5

    return {
        "wall": wall,
        "label": WALLS[wall]["label"],
        "active_state": show.get("ActiveState", "unknown"),
        "sub_state": show.get("SubState", ""),
        "n_restarts": show.get("NRestarts", "?"),
        "active_since": show.get("ActiveEnterTimestamp", ""),
        "connected": connected,
        "progress": progress or {},
    }


def server_stats():
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
            {"WWW-Authenticate": 'Basic realm="Video Wall Admin"'},
        )


# ---------- routes ----------

@app.route("/")
def dashboard():
    return render_template("index.html", walls=list(WALLS.keys()))


@app.route("/api/status")
def api_status():
    return jsonify({
        "server": server_stats(),
        "walls": [wall_status(w) for w in WALLS],
    })


def save_wall(wall, form):
    errors = []
    try:
        rows = int(form.get("rows", ""))
        cols = int(form.get("cols", ""))
        canvas_w = int(form.get("canvas_w", ""))
        canvas_h = int(form.get("canvas_h", ""))
        port = int(form.get("port", ""))
        bitrate_kbps = int(form.get("bitrate_kbps", ""))
        fps = int(form.get("fps", ""))
    except ValueError:
        return ["All numeric fields must be whole numbers."]

    if rows < 1 or cols < 1:
        errors.append("Rows/columns must be at least 1.")
    if canvas_w < 2 or canvas_h < 2:
        errors.append("Canvas size must be positive.")
    if not (1 <= port <= 65535):
        errors.append("Port must be between 1 and 65535.")
    if bitrate_kbps < 100:
        errors.append("Bitrate seems too low (minimum 100 kbps).")
    if not (1 <= fps <= 60):
        errors.append("FPS must be between 1 and 60.")

    urls = [
        line.strip() for line in form.get("cameras", "").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    expected = rows * cols
    if len(urls) != expected:
        errors.append(f"Expected {expected} camera URLs (rows x cols) but got {len(urls)}.")

    if errors:
        return errors

    cameras_file = str(ETC / f"cameras-{wall}.conf")
    write_cameras(cameras_file, urls)
    write_wall_env(wall, {
        "rows": rows, "cols": cols, "canvas_w": canvas_w, "canvas_h": canvas_h,
        "port": port, "bitrate_kbps": bitrate_kbps, "fps": fps,
        "cameras_file": cameras_file,
    })
    restart_service(WALLS[wall]["service"])
    return []


def save_global(form):
    rtsp_transport = form.get("rtsp_transport", "tcp")
    if rtsp_transport not in ("tcp", "udp"):
        return ["RTSP transport must be tcp or udp."]
    try:
        srt_latency_ms = int(form.get("srt_latency_ms", ""))
        if srt_latency_ms < 0:
            raise ValueError
    except ValueError:
        return ["SRT latency must be a non-negative whole number of ms."]
    vaapi = "1" if form.get("vaapi") == "on" else "0"

    write_global_env({
        "rtsp_transport": rtsp_transport,
        "srt_latency_ms": srt_latency_ms,
        "vaapi": vaapi,
    })
    for wall in WALLS:
        restart_service(WALLS[wall]["service"])
    return []


@app.route("/config", methods=["GET", "POST"])
def config():
    errors = []
    saved = None
    if request.method == "POST":
        form_type = request.form.get("form")
        if form_type == "global":
            errors = save_global(request.form)
            saved = "global"
        elif form_type in WALLS:
            errors = save_wall(form_type, request.form)
            saved = form_type
        if saved and not errors:
            return redirect(url_for("config", saved=saved))

    wall_data = {w: read_wall_env(w) for w in WALLS}
    camera_data = {
        w: read_cameras(wall_data[w].get("CAMERAS_FILE", str(ETC / f"cameras-{w}.conf")))
        for w in WALLS
    }
    return render_template(
        "config.html",
        walls=WALLS,
        wall_data=wall_data,
        camera_data=camera_data,
        global_data=read_global_env(),
        errors=errors,
        saved=request.args.get("saved"),
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
