"""Shared source-probing helpers for both video wall web UIs.

Deployed to /opt/videowall/webui/probe.py on BOTH the server and the Pi by
their respective install.sh. Keep it here, not duplicated per tree: this is
version-sensitive classification logic (it matches against ffprobe's error
strings), and the README tells operators to extend _UNREACHABLE_HINTS for
their ffmpeg build. Duplicated, that instruction would silently fix only one
machine.

The single entry point is probe_source(), which answers two questions the way
an operator asks them: is the address/port reachable, and is a stream actually
being published there.
"""

import json
import re
import subprocess

FFPROBE = "/usr/bin/ffprobe"

# Errors that mean the connection never got established, so the address/port
# is genuinely unreachable. Checked BEFORE _AMBIGUOUS_HINTS, because
# "connection timed out" is a connect-stage failure while a bare "timed out"
# can also come from a *stream*-level stall on a perfectly reachable host.
_UNREACHABLE_HINTS = (
    "connection timed out",
    "connection refused",
    "no route to host",
    "network is unreachable",
    "host is down",
    "temporary failure in name resolution",
    "name or service not known",
    "failed to resolve hostname",
    "no such host",
)

# Genuinely ambiguous: the host answered (or we can't tell) but no stream
# arrived in time. Reported as a third "inconclusive" state rather than being
# forced into reachable/unreachable, which is what the old bare "timed out"
# match got wrong when triaging many cameras at once.
_AMBIGUOUS_HINTS = (
    "timed out",
    "timeout",
)


def redact_url(url):
    """Mask the secret parts of a stream URL for display.

    UniFi Protect RTSP paths ARE the credential (rtsp://host:7447/<token>),
    and ffprobe echoes full URLs in its errors. Never show a raw URL in a web
    response: it ends up in browser caches and in screenshots pasted into
    tickets. Keeps scheme/host/port and the last few characters of the path so
    a human can still tell which camera is which.
    """
    if not url:
        return ""
    url = re.sub(r"//[^/@]*@", "//", url, count=1)  # drop any user:pass@
    m = re.match(r"^(\w+://[^/?#]+)(.*)$", url)
    if not m:
        return "(hidden)"
    base, rest = m.group(1), m.group(2)
    tail = re.sub(r"[?#].*$", "", rest).rstrip("/")
    if len(tail) > 5:
        return f"{base}/…{tail[-4:]}"
    return base + rest


def _fps_from(stream):
    raw = stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "0/0"
    try:
        num, den = raw.split("/")
        return round(int(num) / int(den), 1) if int(den) else None
    except (ValueError, ZeroDivisionError):
        return None


def probe_source(url, timeout_s=8, rtsp_transport=None, analyze_us=None):
    """Probe a stream URL and report reachability + stream detection.

    For SRT this performs the caller handshake (proving the address/port is
    reachable) and reads stream metadata (proving something is published) in
    one shot. A separate raw UDP port check would be meaningless: a silent
    open UDP port and a firewalled one look identical from outside.

    rtsp_transport should be passed for RTSP sources so the probe exercises
    the SAME transport the encoder uses. Without it ffprobe defaults to
    UDP-first, so a camera could pass the probe and still break a TCP
    encoder, or vice versa.

    Returns a dict with:
      accessible      True / False / None (None = could not run ffprobe)
      stream_detected bool
      reason          'ok' | 'no_stream' | 'unreachable' | 'inconclusive'
                      | 'error' | 'no_ffprobe'
      details         codec/width/height/fps/bitrate_kbps when detected
      error           human-readable message (never raw stderr with URLs)
    """
    probe_url = url
    if url.startswith("srt://"):
        sep = "&" if "?" in url else "?"
        probe_url = f"{url}{sep}timeout={int(max(timeout_s - 2, 1) * 1_000_000)}"

    cmd = [FFPROBE, "-v", "error", "-print_format", "json",
           "-show_streams", "-show_format", "-select_streams", "v:0"]
    if rtsp_transport and url.startswith("rtsp"):
        cmd += ["-rtsp_transport", rtsp_transport]
    if analyze_us:
        # Without these, ffprobe on a 4K H.264 stream routinely burns several
        # seconds just filling its probe buffer.
        cmd += ["-analyzeduration", str(analyze_us),
                "-probesize", str(max(analyze_us // 2, 100_000))]
    cmd.append(probe_url)

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"accessible": None, "stream_detected": False, "reason": "inconclusive",
                "error": f"No answer within {timeout_s}s — unreachable, or nothing "
                         "is publishing there."}
    except (FileNotFoundError, OSError):
        return {"accessible": None, "stream_detected": False, "reason": "no_ffprobe",
                "error": "ffprobe not found (install the ffmpeg package)."}

    if res.returncode == 0 and (res.stdout or "").strip():
        try:
            data = json.loads(res.stdout)
        except json.JSONDecodeError:
            data = {}
        vstreams = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
        if vstreams:
            v = vstreams[0]
            bitrate = data.get("format", {}).get("bit_rate")
            return {
                "accessible": True, "stream_detected": True, "reason": "ok",
                "details": {
                    "codec": v.get("codec_name"),
                    "width": v.get("width"),
                    "height": v.get("height"),
                    "fps": _fps_from(v),
                    "bitrate_kbps": int(bitrate) // 1000 if bitrate else None,
                },
            }
        return {"accessible": True, "stream_detected": False, "reason": "no_stream",
                "error": "Connected, but no video stream was found."}

    low = (res.stderr or "").lower()
    if any(h in low for h in _UNREACHABLE_HINTS):
        return {"accessible": False, "stream_detected": False, "reason": "unreachable",
                "error": "Could not connect — check the address, port and firewall."}
    if any(h in low for h in _AMBIGUOUS_HINTS):
        return {"accessible": None, "stream_detected": False, "reason": "inconclusive",
                "error": "Connected or reachable, but no stream arrived in time."}
    return {"accessible": True, "stream_detected": False, "reason": "error",
            "error": "The source answered but could not be read as a stream."}
