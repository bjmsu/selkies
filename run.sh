#!/usr/bin/env bash
#
# Build the web frontend, set up a Python venv, and start Selkies-GStreamer
# listening on port 8080 (override with PORT=... ./start.sh).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"
WEB_DIST="$ROOT/gst-web-dist"

: "${PORT:=8080}"
# AES-256-GCM encrypted secret (see tools/gen_basic_auth_secret.py) — only the
# ciphertext lives here, never the plaintext password.
: "${BASIC_AUTH_PASSWORD_ENC:=mz+g05mWFdLq2TI3bBaBlqIQjInxHA6M8mhtOK+lt9iS0NyxSmC+/rXMgtROwZKS50Kedemgz+emcwov588dpV5z46mTQQtp2A==}"
: "${ENCODER:=vah264enc}"
: "${ENABLE_HTTPS:=false}"

echo "==> Checking system dependencies (gi, GStreamer)"
if ! python3 -c "import gi" >/dev/null 2>&1; then
    echo "Missing python3-gi. Install system dependencies first, see docs/start.md, e.g.:" >&2
    echo "  sudo apt-get install --no-install-recommends -y python3-gi libgirepository-1.0-1 glib-networking" >&2
    exit 1
fi
if ! command -v gst-inspect-1.0 >/dev/null 2>&1; then
    echo "Missing GStreamer (gst-inspect-1.0 not found). Install it first, see docs/start.md." >&2
    exit 1
fi

echo "==> Setting up venv"
venv_is_new=false
if [ ! -f "$VENV/bin/activate" ]; then
    python3 -m venv --system-site-packages "$VENV"
    venv_is_new=true
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
# Only (re)install on first setup or when explicitly asked (REINSTALL=true
# ./run.sh) — pip resolving/rebuilding the python-xlib GitHub zip dependency
# every run is what makes this step slow.
if [ "$venv_is_new" = true ] || [ "${REINSTALL:-false}" = "true" ]; then
    # Upgrade the build toolchain first: an outdated/broken setuptools in pip's
    # isolated build env is a common cause of "cannot import name 'setup' from
    # setuptools" when installing legacy setup.py-only deps (e.g. python-xlib).
    pip install --quiet --disable-pip-version-check --upgrade pip setuptools wheel
    pip install --quiet --disable-pip-version-check -e "$ROOT"
fi

echo "==> Building web frontend into $WEB_DIST"
(cd "$ROOT/addons/gst-web" && INSTALL_DIR="$WEB_DIST" ./install.sh)

echo "==> Detecting DISPLAY"
if [ -z "${DISPLAY:-}" ]; then
    xorg_line="$(ps -eo args | grep -E '(^|/)Xorg(\.bin)?[[:space:]]' | grep -v grep | head -1)"
    if [ -n "$xorg_line" ]; then
        DISPLAY="$(echo "$xorg_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^:[0-9]+$/) {print $i; exit}}')"
    fi
fi
if [ -z "${DISPLAY:-}" ]; then
    echo "No running Xorg process found. Log in to an X session (e.g. via xrdp) first, or set DISPLAY manually." >&2
    exit 1
fi
export DISPLAY
echo "    DISPLAY=$DISPLAY"

echo "==> Detecting XAUTHORITY"
if [ -z "${XAUTHORITY:-}" ]; then
    xrdp_auth="/var/run/xrdp/$(id -u)/Xauthority"
    if [ -f "$xrdp_auth" ]; then
        XAUTHORITY="$xrdp_auth"
    fi
fi
export XAUTHORITY
echo "    XAUTHORITY=${XAUTHORITY:-<default>}"

echo "==> Starting selkies-gstreamer on port $PORT"
exec selkies-gstreamer \
    --addr=0.0.0.0 \
    --port="$PORT" \
    --web_root="$WEB_DIST" \
    --enable_https="$ENABLE_HTTPS" \
    --basic_auth_password_enc="$BASIC_AUTH_PASSWORD_ENC" \
    --encoder="$ENCODER" \
    --enable_resize=false
