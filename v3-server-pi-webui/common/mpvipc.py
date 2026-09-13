"""Talk to a running mpv over its JSON IPC socket.

Each display is started with --input-ipc-server=<socket>, which turns mpv from
an opaque process into something we can actually ask "are you still playing?".
Without this, the only available health signal is "the process exists", which
stays true for a stream that froze hours ago.

Adapted from the displaycameras-modern project (Apache License 2.0,
Copyright 2026 Miguel Costa) — see NOTICE.

Usable as a module (the watchdog and the web UI import it) or from a shell:

    python3 mpvipc.py getprop <socket> time-pos
    python3 mpvipc.py loadfile <socket> <url>
"""

import json
import socket
import sys

DEFAULT_TIMEOUT = 1.5


class MpvIPC:
    """A one-shot connection to an mpv IPC socket.

    Deliberately connects per command rather than holding a socket open: mpv
    restarts underneath us whenever a display loop relaunches it, and a stale
    persistent connection would report a dead player as healthy.
    """

    def __init__(self, path, timeout=DEFAULT_TIMEOUT):
        self.path = str(path)
        self.timeout = timeout

    def command(self, *args):
        """Send one command, return its reply dict, or None if unreachable."""
        req_id = 1
        payload = json.dumps({"command": list(args), "request_id": req_id}) + "\n"
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(self.timeout)
            s.connect(self.path)
        except (OSError, socket.timeout):
            return None
        try:
            s.sendall(payload.encode("utf-8"))
            buf = b""
            while True:
                try:
                    chunk = s.recv(65536)
                except (OSError, socket.timeout):
                    return None
                if not chunk:
                    return None
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        msg = json.loads(line.decode("utf-8"))
                    except ValueError:
                        continue
                    # mpv interleaves asynchronous events; wait for our reply.
                    if msg.get("request_id") == req_id:
                        return msg
        finally:
            s.close()

    def get(self, prop, default=None):
        """Read one property. Returns default if mpv is unreachable or the
        property is unavailable (mpv reports null for e.g. time-pos while
        nothing is loaded)."""
        reply = self.command("get_property", prop)
        if not reply or reply.get("error") != "success":
            return default
        data = reply.get("data")
        return default if data is None else data

    def loadfile(self, url):
        """Reconnect in place, without killing mpv.

        Cheaper and less disruptive than tearing the player down: no black
        screen, no window churn, and it forces a fresh connection (and so a
        fresh keyframe) on a stream that had silently degraded.
        """
        reply = self.command("loadfile", url, "replace")
        return bool(reply and reply.get("error") == "success")

    def responsive(self):
        """True if mpv answers at all — distinguishes 'not running yet' from
        'running but stuck'."""
        return self.command("get_property", "mpv-version") is not None


def _fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float, str)):
        return str(value)
    return json.dumps(value)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    action, sockpath, args = argv[1], argv[2], argv[3:]
    mpv = MpvIPC(sockpath)

    if action == "getprop":
        if not args:
            sys.stderr.write("getprop needs a property name\n")
            return 2
        value = mpv.get(args[0])
        if value is None:
            return 3
        print(_fmt(value))
        return 0
    if action == "loadfile":
        return 0 if args and mpv.loadfile(args[0]) else 1
    if action == "quit":
        return 0 if mpv.command("quit") else 1
    if action == "cmd":
        reply = mpv.command(*args)
        if reply is None:
            return 1
        print(_fmt(reply.get("data", reply.get("error", ""))))
        return 0 if reply.get("error") == "success" else 4

    sys.stderr.write("Unknown action: %s\n" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
