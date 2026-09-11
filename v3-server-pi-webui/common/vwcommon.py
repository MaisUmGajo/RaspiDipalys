"""Helpers shared by both video wall web UIs (server and Pi).

Deployed alongside probe.py to /opt/videowall/webui/ by both install.sh
scripts. These were byte-identical copies in the two apps; keeping one copy
means a fix lands on both machines.
"""

from pathlib import Path

from flask import Response, request
from werkzeug.security import check_password_hash


def parse_env_file(path):
    """Read a KEY=VALUE config file, ignoring comments and blank lines."""
    values = {}
    path = Path(path)
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def check_auth(creds_path, auth):
    """Validate HTTP Basic credentials against a hashed password on disk.

    Fails closed: a missing or hash-less credentials file denies everything
    rather than allowing access.
    """
    creds = parse_env_file(creds_path)
    expected_user = creds.get("WEBUI_USER", "")
    expected_hash = creds.get("WEBUI_PASSWORD_HASH", "")
    if not auth or not expected_hash or auth.username != expected_user:
        return False
    return check_password_hash(expected_hash, auth.password)


def install_basic_auth(app, creds_path, realm):
    """Gate every request on this app behind HTTP Basic auth."""

    @app.before_request
    def _require_auth():
        if not check_auth(creds_path, request.authorization):
            return Response(
                "Authentication required.", 401,
                {"WWW-Authenticate": f'Basic realm="{realm}"'},
            )
