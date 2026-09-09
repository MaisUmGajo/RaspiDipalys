import fcntl
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psutil
from flask import (Flask, Response, jsonify, redirect, render_template,
                   request, url_for)

from werkzeug.security import check_password_hash

from probe import probe_source, redact_url
from vwcommon import check_auth, parse_env_file

app = Flask(__name__)

ETC = Path("/etc/videowall")
RUN = Path("/run/videowall")            # written by the encoders
WEBUI_RUN = Path("/run/videowall-web")  # this app's own runtime dir (locks)
SUDO = "/usr/bin/sudo"
VWCTL = "/usr/local/sbin/videowall-ctl"

# Wall slugs must match videowall-ctl's own pattern, or the UI could offer
# names the privileged helper will refuse.
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

PROBE_COOLDOWN_S = 15
PROBE_WORKERS = 5
PROBE_TIMEOUT_S = 5

CREDS = ETC / "webui.env"


@app.before_request
def require_auth():
    """Admin endpoints use HTTP Basic; /api/walls also accepts a read-only
    bearer token so a Pi client can list walls without ever holding the
    server's admin password."""
    if request.path == "/api/walls":
        header = request.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            expected = parse_env_file(CREDS).get("WEBUI_READ_TOKEN_HASH", "")
            if expected and check_password_hash(expected, header[7:].strip()):
                return None
    if not check_auth(CREDS, request.authorization):
        return Response("Authentication required.", 401,
                        {"WWW-Authenticate": 'Basic realm="Video Wall Admin"'})
    return None


# ---------- wall discovery ----------

def wall_env_path(wall):
    return ETC / f"wall-{wall}.env"


def discover_walls():
    """Every configured wall, keyed by slug, in name order.

    Walls are data now, not a hardcoded pair: whatever wall-<slug>.env files
    exist are the walls. Files whose slug is invalid are skipped rather than
    offered to videowall-ctl, which would reject them anyway.
    """
    walls = {}
    for path in sorted(ETC.glob("wall-*.env")):
        slug = path.name[len("wall-"):-len(".env")]
        if SLUG_RE.match(slug):
            walls[slug] = parse_env_file(path)
    return walls


def read_cameras(path_str):
    path = Path(path_str) if path_str else None
    if not path or not path.exists():
        return []
    return [ln.strip() for ln in path.read_text().splitlines()
            if ln.strip() and not ln.strip().startswith("#")]


WALL_ENV_TEMPLATE = """# Per-wall settings for '{slug}'.
# Rewritten by the videowall web UI on every save.

ENABLED={enabled}

ROWS={rows}
COLS={cols}
CANVAS_W={canvas_w}
CANVAS_H={canvas_h}

BITRATE_KBPS={bitrate_kbps}
FPS={fps}

CAMERAS_FILE={cameras_file}
"""


def write_wall_env(slug, data):
    wall_env_path(slug).write_text(WALL_ENV_TEMPLATE.format(slug=slug, **data))


GLOBAL_ENV_TEMPLATE = """# Global settings, shared by every wall.
# Rewritten by the videowall web UI on every save.

RTSP_TRANSPORT={rtsp_transport}
SRT_LATENCY_MS={srt_latency_ms}
VAAPI={vaapi}

MEDIAMTX_RTSP_HOST={mediamtx_rtsp_host}
MEDIAMTX_RTSP_PORT={mediamtx_rtsp_port}
MEDIAMTX_API={mediamtx_api}

SNAPSHOT={snapshot}
SNAPSHOT_WIDTH={snapshot_width}
SNAPSHOT_INTERVAL_S={snapshot_interval_s}
"""


def read_global_env():
    return parse_env_file(ETC / "videowall-server.env")


def write_global_env(data):
    (ETC / "videowall-server.env").write_text(GLOBAL_ENV_TEMPLATE.format(**data))


def write_cameras(path_str, urls):
    header = (f"# {len(urls)} RTSP URLs, one per line, row-major order.\n"
              "# Rewritten by the videowall web UI on every save.\n\n")
    Path(path_str).write_text(header + "\n".join(urls) + ("\n" if urls else ""))


# ---------- privileged control + status ----------

def vwctl(verb, wall):
    """Run one validated systemctl verb via the privileged helper."""
    return subprocess.run([SUDO, VWCTL, verb, wall],
                          check=False, capture_output=True, text=True, timeout=20)


def unit_props(wall):
    res = vwctl("show", wall)
    if res.returncode != 0:
        return {}
    props = {}
    for line in (res.stdout or "").splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k] = v
    return props


def read_progress(wall):
    """Parse ffmpeg's -progress file: repeated key=value blocks each ending in
    a 'progress=' line. Accumulate and flush on each terminator so a torn
    final block is discarded rather than shown as valid."""
    path = RUN / f"progress-{wall}.txt"
    if not path.exists():
        return None
    try:
        text = path.read_text()
    except OSError:
        return None
    last, current = {}, {}
    for line in text.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "progress":
            last, current = current, {}
        else:
            current[key.strip()] = value.strip()
    return last or None


def snapshot_path(wall):
    return RUN / f"snapshot-{wall}.jpg"


def snapshot_age_s(wall):
    try:
        return round(time.time() - snapshot_path(wall).stat().st_mtime, 1)
    except OSError:
        return None


def mediamtx_state():
    """Real per-client data from the relay's API.

    This replaces the old "is the progress file fresh?" inference: MediaMTX
    knows who is actually connected. Returns None if the relay can't be
    reached, so the UI can say so rather than implying zero clients.
    """
    api = read_global_env().get("MEDIAMTX_API", "http://127.0.0.1:9997").rstrip("/")

    def fetch(path):
        with urllib.request.urlopen(f"{api}{path}", timeout=3) as resp:
            return json.loads(resp.read().decode("utf-8"))

    try:
        paths = fetch("/v3/paths/list")
        conns = fetch("/v3/srtconns/list")
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return None

    by_id = {c.get("id"): c for c in conns.get("items", []) if c.get("id")}
    state = {}
    for item in paths.get("items", []):
        readers = []
        for r in item.get("readers", []):
            conn = by_id.get(r.get("id"), {})
            readers.append({
                "type": r.get("type", "?"),
                "addr": conn.get("remoteAddr", ""),
                "bytes_sent": conn.get("bytesSent"),
                "since": conn.get("created", ""),
            })
        state[item.get("name")] = {
            "ready": bool(item.get("ready")),
            "readers": readers,
            "bytes_received": item.get("bytesReceived"),
        }
    return state


def wall_status(slug, env, relay):
    props = unit_props(slug)
    enabled = (env.get("ENABLED", "true").lower() == "true")
    cams = read_cameras(env.get("CAMERAS_FILE"))
    try:
        expected = int(env.get("ROWS", 0)) * int(env.get("COLS", 0))
    except ValueError:
        expected = 0

    relay_entry = (relay or {}).get(slug)
    return {
        "wall": slug,
        "enabled": enabled,
        "rows": env.get("ROWS"), "cols": env.get("COLS"),
        "canvas": f"{env.get('CANVAS_W', '?')}x{env.get('CANVAS_H', '?')}",
        "bitrate_kbps": env.get("BITRATE_KBPS"),
        "fps": env.get("FPS"),
        "active_state": props.get("ActiveState", "unknown"),
        "sub_state": props.get("SubState", ""),
        "n_restarts": props.get("NRestarts", "?"),
        "exec_status": props.get("ExecMainStatus", ""),
        "progress": read_progress(slug) or {},
        "snapshot_age_s": snapshot_age_s(slug),
        # None distinguishes "relay unreachable" from "relay says nobody".
        "relay_known": relay is not None,
        "published": bool(relay_entry and relay_entry["ready"]),
        "readers": (relay_entry or {}).get("readers", []),
        "camera_count": len(cams),
        "camera_expected": expected,
        "config_ok": expected > 0 and len(cams) == expected,
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


# ---------- routes: dashboard ----------

@app.route("/")
def dashboard():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    relay = mediamtx_state()
    walls = discover_walls()
    return jsonify({
        "server": server_stats(),
        "relay_up": relay is not None,
        "walls": [wall_status(slug, env, relay) for slug, env in walls.items()],
    })


@app.route("/api/walls")
def api_walls():
    """Read-only wall list for client (Pi) wall pickers.

    Deliberately minimal: names, geometry and enabled state — no camera URLs,
    since those are credential-bearing.
    """
    relay = mediamtx_state()
    walls = []
    for slug, env in discover_walls().items():
        walls.append({
            "wall": slug,
            "enabled": env.get("ENABLED", "true").lower() == "true",
            "rows": env.get("ROWS"), "cols": env.get("COLS"),
            "canvas_w": env.get("CANVAS_W"), "canvas_h": env.get("CANVAS_H"),
            "published": bool((relay or {}).get(slug, {}).get("ready")),
        })
    g = read_global_env()
    return jsonify({
        "walls": walls,
        "srt_latency_ms": g.get("SRT_LATENCY_MS", "400"),
    })


@app.route("/snapshot/<wall>.jpg")
def snapshot(wall):
    """Serve the newest mosaic frame.

    ffmpeg writes this with -atomic_writing, so a torn read shouldn't happen —
    but we still verify the JPEG end-of-image marker and retry once, because a
    broken image in the dashboard is indistinguishable from a broken wall.
    """
    if not SLUG_RE.match(wall):
        return Response("bad wall name", 400)
    path = snapshot_path(wall)
    for attempt in (0, 1):
        try:
            data = path.read_bytes()
        except OSError:
            return Response("no snapshot yet", 404)
        if data[-2:] == b"\xff\xd9":
            resp = Response(data, mimetype="image/jpeg")
            resp.headers["Cache-Control"] = "no-store"
            return resp
        if attempt == 0:
            time.sleep(0.1)
    return Response("snapshot incomplete", 503)


# ---------- routes: per-camera probe ----------

def probe_gate(wall):
    """Cross-process cooldown for the probe.

    gunicorn runs multiple workers, so a module-level dict would not be
    shared and two workers could both fire a probe. The lock file lives in
    this app's own runtime dir (the encoders' /run/videowall is not writable
    by this user).
    """
    WEBUI_RUN.mkdir(parents=True, exist_ok=True)
    lock = WEBUI_RUN / f"probe-{wall}.lock"
    existed = lock.exists()
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None, 0.0
    if existed:
        age = time.time() - os.fstat(fd).st_mtime
        if age < PROBE_COOLDOWN_S:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            return None, round(PROBE_COOLDOWN_S - age, 1)
    os.utime(lock, None)
    return fd, 0.0


@app.route("/api/probe/<wall>", methods=["POST"])
def api_probe(wall):
    if not SLUG_RE.match(wall):
        return jsonify({"error": "bad wall name"}), 400
    walls = discover_walls()
    if wall not in walls:
        return jsonify({"error": "no such wall"}), 404

    env = walls[wall]
    urls = read_cameras(env.get("CAMERAS_FILE"))
    try:
        rows, cols = int(env.get("ROWS", 0)), int(env.get("COLS", 0))
    except ValueError:
        rows = cols = 0
    expected = rows * cols

    # The most common real root cause, and the encoder already refuses to
    # start on it — so say it plainly instead of probing into the void.
    if expected and len(urls) != expected:
        return jsonify({
            "wall": wall, "cameras": [],
            "error": f"Camera list has {len(urls)} URLs but the "
                     f"{rows}x{cols} grid needs {expected} — this wall cannot start.",
        })

    fd, retry_in = probe_gate(wall)
    if fd is None:
        return jsonify({"wall": wall, "cameras": [], "cooldown": retry_in,
                        "error": f"Checked very recently — try again in {retry_in}s."}), 429

    transport = read_global_env().get("RTSP_TRANSPORT", "tcp")
    try:
        def one(idx_url):
            idx, url = idx_url
            r = probe_source(url, timeout_s=PROBE_TIMEOUT_S,
                             rtsp_transport=transport, analyze_us=1_000_000)
            r.update({
                "index": idx,
                "row": idx // cols if cols else 0,
                "col": idx % cols if cols else idx,
                # Never return the raw URL: Protect paths are the credential.
                "url": redact_url(url),
            })
            return r

        with ThreadPoolExecutor(max_workers=PROBE_WORKERS) as pool:
            results = list(pool.map(one, enumerate(urls)))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    return jsonify({"wall": wall, "rows": rows, "cols": cols,
                    "transport": transport, "cameras": results})


# ---------- routes: config ----------

def validate_wall_form(form, slug):
    errors = []
    try:
        nums = {k: int(form.get(k, "")) for k in
                ("rows", "cols", "canvas_w", "canvas_h", "bitrate_kbps", "fps")}
    except ValueError:
        return None, ["Rows, columns, canvas size, bitrate and FPS must be whole numbers."]

    if nums["rows"] < 1 or nums["cols"] < 1:
        errors.append("Rows and columns must be at least 1.")
    if nums["canvas_w"] < 2 or nums["canvas_h"] < 2:
        errors.append("Canvas size must be positive.")
    if nums["bitrate_kbps"] < 100:
        errors.append("Bitrate seems too low (minimum 100 kbps).")
    if not (1 <= nums["fps"] <= 60):
        errors.append("FPS must be between 1 and 60.")

    urls = [ln.strip() for ln in form.get("cameras", "").splitlines()
            if ln.strip() and not ln.strip().startswith("#")]
    expected = nums["rows"] * nums["cols"]
    if len(urls) != expected:
        errors.append(f"Expected {expected} camera URLs (rows x columns) "
                      f"but got {len(urls)}.")
    return (nums, urls), errors


def save_wall(slug, form):
    parsed, errors = validate_wall_form(form, slug)
    if errors:
        return errors
    nums, urls = parsed
    cameras_file = str(ETC / f"cameras-{slug}.conf")
    write_cameras(cameras_file, urls)
    write_wall_env(slug, {
        "enabled": "true" if form.get("enabled") == "on" else "false",
        "cameras_file": cameras_file, **nums,
    })
    apply_wall_state(slug)
    return []


def apply_wall_state(slug):
    """Make systemd agree with the wall's ENABLED flag."""
    env = parse_env_file(wall_env_path(slug))
    if env.get("ENABLED", "true").lower() == "true":
        vwctl("enable", slug)
        vwctl("restart", slug)
    else:
        vwctl("stop", slug)
        vwctl("disable", slug)


def create_wall(form):
    slug = (form.get("slug") or "").strip().lower()
    if not SLUG_RE.match(slug):
        return ["Wall name must be lowercase letters/digits, then letters, "
                "digits, underscore or hyphen (max 32 characters)."]
    if wall_env_path(slug).exists():
        return [f"A wall named '{slug}' already exists."]
    parsed, errors = validate_wall_form(form, slug)
    if errors:
        return errors
    nums, urls = parsed
    cameras_file = str(ETC / f"cameras-{slug}.conf")
    write_cameras(cameras_file, urls)
    write_wall_env(slug, {
        "enabled": "true" if form.get("enabled") == "on" else "false",
        "cameras_file": cameras_file, **nums,
    })
    apply_wall_state(slug)
    return []


def delete_wall(slug):
    if slug not in discover_walls():
        return ["No such wall."]
    # Stop and disable BEFORE removing config, so nothing is left running
    # against a wall that no longer exists.
    vwctl("stop", slug)
    vwctl("disable", slug)
    env = parse_env_file(wall_env_path(slug))
    cams = env.get("CAMERAS_FILE")
    wall_env_path(slug).unlink(missing_ok=True)
    if cams and Path(cams).parent == ETC:
        Path(cams).unlink(missing_ok=True)
    return []


def save_global(form):
    try:
        srt_latency_ms = int(form.get("srt_latency_ms", ""))
        mediamtx_rtsp_port = int(form.get("mediamtx_rtsp_port", ""))
        snapshot_width = int(form.get("snapshot_width", ""))
        snapshot_interval_s = int(form.get("snapshot_interval_s", ""))
    except ValueError:
        return ["SRT latency, relay port, snapshot width and interval must be "
                "whole numbers."]
    transport = form.get("rtsp_transport", "tcp")
    if transport not in ("tcp", "udp"):
        return ["RTSP transport must be tcp or udp."]
    if srt_latency_ms < 0:
        return ["SRT latency must be non-negative."]
    if snapshot_width < 320:
        return ["Snapshot width below 320px is too coarse to be useful."]
    if snapshot_interval_s < 1:
        return ["Snapshot interval must be at least 1 second."]

    write_global_env({
        "rtsp_transport": transport,
        "srt_latency_ms": srt_latency_ms,
        "vaapi": "1" if form.get("vaapi") == "on" else "0",
        "mediamtx_rtsp_host": form.get("mediamtx_rtsp_host", "127.0.0.1").strip(),
        "mediamtx_rtsp_port": mediamtx_rtsp_port,
        "mediamtx_api": form.get("mediamtx_api", "http://127.0.0.1:9997").strip(),
        "snapshot": "1" if form.get("snapshot") == "on" else "0",
        "snapshot_width": snapshot_width,
        "snapshot_interval_s": snapshot_interval_s,
    })
    # Global settings affect every wall, so every running wall restarts.
    for slug, env in discover_walls().items():
        if env.get("ENABLED", "true").lower() == "true":
            vwctl("restart", slug)
    return []


@app.route("/config", methods=["GET", "POST"])
def config():
    errors = []
    if request.method == "POST":
        action = request.form.get("action")
        target = request.form.get("wall", "")
        if action == "global":
            errors = save_global(request.form)
            if not errors:
                return redirect(url_for("config", saved="global"))
        elif action == "create":
            errors = create_wall(request.form)
            if not errors:
                return redirect(url_for("config", saved="created"))
        elif action == "save" and SLUG_RE.match(target):
            errors = save_wall(target, request.form)
            if not errors:
                return redirect(url_for("config", saved=target))
        elif action == "delete" and SLUG_RE.match(target):
            errors = delete_wall(target)
            if not errors:
                return redirect(url_for("config", saved="deleted"))
        elif action in ("enable", "disable") and SLUG_RE.match(target):
            env = parse_env_file(wall_env_path(target))
            if env:
                env["ENABLED"] = "true" if action == "enable" else "false"
                write_wall_env(target, {
                    "enabled": env["ENABLED"],
                    "rows": env.get("ROWS", 1), "cols": env.get("COLS", 1),
                    "canvas_w": env.get("CANVAS_W", 1920),
                    "canvas_h": env.get("CANVAS_H", 1080),
                    "bitrate_kbps": env.get("BITRATE_KBPS", 4000),
                    "fps": env.get("FPS", 15),
                    "cameras_file": env.get("CAMERAS_FILE",
                                            str(ETC / f"cameras-{target}.conf")),
                })
                apply_wall_state(target)
                return redirect(url_for("config", saved=target))
            errors = ["No such wall."]
        else:
            errors = ["Unknown action."]

    walls = discover_walls()
    return render_template(
        "config.html",
        walls=walls,
        cameras={slug: read_cameras(env.get("CAMERAS_FILE"))
                 for slug, env in walls.items()},
        global_data=read_global_env(),
        errors=errors,
        saved=request.args.get("saved"),
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
