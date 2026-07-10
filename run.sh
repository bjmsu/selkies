#!/usr/bin/env bash
#
# Start Selkies-GStreamer from this repo's source on the bundled GStreamer
# runtime in ./gstreamer — no system GStreamer, no venv, no root needed.
# Usage: ./run.sh   (override with e.g. PORT=8081 ENCODER=x264enc FRAMERATE=60 ./run.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GST_ENV="$ROOT/gstreamer"
WEB_DIST="$ROOT/gst-web-dist"

: "${PORT:=8080}"
# AES-256-GCM encrypted secret (see tools/gen_basic_auth_secret.py) — only the
# ciphertext lives here, never the plaintext password.
: "${BASIC_AUTH_PASSWORD_ENC:=mz+g05mWFdLq2TI3bBaBlqIQjInxHA6M8mhtOK+lt9iS0NyxSmC+/rXMgtROwZKS50Kedemgz+emcwov588dpV5z46mTQQtp2A==}"
: "${ENCODER:=vah264enc}"
: "${ENABLE_HTTPS:=false}"
# -1 = infinite GOP: no periodic large I-frames, so no recurring transmission
# spike every N seconds. Packet loss is covered by WebRTC's PLI mechanism —
# the browser requests a keyframe and webrtcbin forces one from the encoder
# on demand, so corruption self-heals in about one round trip.
: "${KEYFRAME_DISTANCE:=-1}"
# 30fps halves the CPU cost of X11 screen capture (the biggest consumer)
# versus the upstream default of 60.
: "${FRAMERATE:=60}"
# LAN has bandwidth to spare; 16 Mbps keeps text noticeably sharper than the
# upstream 8 Mbps default. The web UI's bitrate setting still overrides this.
: "${VIDEO_BITRATE:=16000}"
# Resize the remote X display to match the browser window (1:1 pixels,
# sharpest text). Fully works on the virtual display; on the xrdp session
# xorgxrdp rejects X-initiated screen size changes, so it has no effect there.
: "${RESIZE:=true}"
# true = run a dedicated virtual desktop (Xvfb + Plasma) that supports dynamic
# resolution; false = mirror the existing xrdp session (shared desktop, but
# fixed resolution — xorgxrdp forbids in-session resize).
: "${VIRTUAL:=true}"
: "${VDISPLAY:=:20}"
# Initial size of the virtual desktop before the first browser resize; also
# shrinks the 8192x4096 framebuffer Xvfb must start with (its RANDR maximum
# is fixed at startup, so it starts large and resizes down).
: "${VSTARTRES:=1920x1080}"

if [ ! -f "$GST_ENV/bin/activate" ]; then
    echo "Bundled GStreamer runtime not found at $GST_ENV" >&2
    echo "Extract selkies-gstreamer-portable-v1.6.2_amd64.tar.gz there first." >&2
    exit 1
fi

echo "==> Entering bundled GStreamer runtime ($GST_ENV)"
# conda's activate script trips over `set -u`; relax it while sourcing
set +u
# shellcheck disable=SC1091
source "$GST_ENV/bin/activate"
set -u
export GSTREAMER_PATH="$CONDA_PREFIX"
export PATH="$GSTREAMER_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$GSTREAMER_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GST_PLUGIN_PATH="$GSTREAMER_PATH/lib/gstreamer-1.0:$ROOT/plugins"
export GI_TYPELIB_PATH="$GSTREAMER_PATH/lib/girepository-1.0"
# Private plugin registry so caches from other GStreamer installs never leak in
export GST_REGISTRY="$GST_ENV/.gst-registry.bin"

# The bundled libva cannot locate the host VA driver on its own; without these
# the va plugin registers zero elements and hardware encoding silently
# disappears (selkies then fails to build the vah264enc pipeline).
export LIBVA_DRIVERS_PATH="${LIBVA_DRIVERS_PATH:-/usr/lib/x86_64-linux-gnu/dri}"
export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-iHD}"

# PulseAudio/PipeWire socket for audio capture
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR}/pulse}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"

# Build the yuvconv plugin (single-pass SIMD BGRx->NV12 via libyuv, roughly
# halves streaming CPU vs videoconvert) when missing or its source changed.
# selkies falls back to videoconvert automatically if this fails.
if [ -f "$ROOT/plugins/gstyuvconv.c" ] && command -v gcc >/dev/null; then
    if [ ! -f "$ROOT/plugins/libgstyuvconv.so" ] || [ "$ROOT/plugins/gstyuvconv.c" -nt "$ROOT/plugins/libgstyuvconv.so" ]; then
        echo "==> Building yuvconv plugin"
        (cd "$ROOT/plugins" && PKG_CONFIG_PATH="$GSTREAMER_PATH/lib/pkgconfig" \
            gcc -O2 -shared -fPIC gstyuvconv.c -o libgstyuvconv.so \
            $(PKG_CONFIG_PATH="$GSTREAMER_PATH/lib/pkgconfig" pkg-config --define-prefix --cflags --libs gstreamer-video-1.0) -ldl) \
            || echo "    yuvconv build failed, selkies will fall back to videoconvert"
    fi
fi

echo "==> Building web frontend into $WEB_DIST"
(cd "$ROOT/addons/gst-web" && INSTALL_DIR="$WEB_DIST" ./install.sh)

if [ "$VIRTUAL" = "true" ]; then
    echo "==> Virtual desktop mode on $VDISPLAY"
    export DISPLAY="$VDISPLAY"
    # Xvfb runs with -ac (no auth) on a unix socket only.
    export XAUTHORITY=""

    XVFB_BIN="$ROOT/bin/Xvfb"
    [ -x "$XVFB_BIN" ] || XVFB_BIN="$(command -v Xvfb || true)"
    if [ -z "$XVFB_BIN" ]; then
        echo "Xvfb not found (expected at $ROOT/bin/Xvfb)." >&2
        exit 1
    fi

    if [ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
        # The display is gone (reboot, or Xvfb died): clients of the old
        # instance are stuck on a dead socket — plasmashell in particular
        # spins at 100% CPU there and would fool the session check below,
        # leaving the fresh display black. Clear them out first.
        for stale in $(pgrep -u "$USER"); do
            [ "$stale" = "$$" ] && continue
            if grep -qz "DISPLAY=$DISPLAY" "/proc/$stale/environ" 2>/dev/null; then
                echo "    killing stale $DISPLAY client: $stale ($(cat /proc/$stale/comm 2>/dev/null))"
                kill "$stale" 2>/dev/null || true
            fi
        done
        echo "    starting Xvfb"
        # setsid: detach from this script's process group so Ctrl-C on run.sh
        # restarts only selkies and leaves the desktop running.
        setsid "$XVFB_BIN" "$DISPLAY" -screen 0 8192x4096x24 \
            +extension COMPOSITE +extension DAMAGE +extension GLX \
            +extension RANDR +extension RENDER +extension MIT-SHM \
            +extension XFIXES +extension XTEST +iglx +render \
            -nolisten tcp -ac -noreset >"$ROOT/.xvfb.log" 2>&1 &
        until [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do sleep 0.2; done
    fi

    # Set the initial resolution (resize.py is stdlib-only, system python3 is fine)
    PYTHONPATH="$ROOT/src/selkies_gstreamer" python3 -c "from resize import resize_display; resize_display('$VSTARTRES')" || true

    # Start a Plasma session on this display unless one is already running
    session_running=false
    for pid in $(pgrep -x plasmashell 2>/dev/null); do
        if grep -qz "DISPLAY=$DISPLAY" "/proc/$pid/environ" 2>/dev/null; then
            session_running=true
            break
        fi
    done
    if [ "$session_running" = "false" ]; then
        echo "    starting KDE Plasma session (log: $ROOT/.plasma.log)"
        # Compositing (kwin on llvmpipe) is ON: CSD apps (Telegram,
        # Thunderbird...) draw alpha shadows that render as solid black frames
        # without a compositor. Costs some CPU; set KWIN_COMPOSE=N here to
        # trade the shadows back for lower load.
        # QT_QUICK_BACKEND=software: plasmashell's QtQuick scene graph through
        # llvmpipe GL costs more CPU than plain software rasterization on a
        # virtual display.
        # env -i: the bundled runtime's PATH/LD_LIBRARY_PATH must NOT leak
        # into the desktop session — the bundle ships its own dbus-run-session
        # with a broken hardcoded config path, and its libraries would shadow
        # the system ones KDE links against.
        # setsid: survive Ctrl-C on run.sh — the desktop persists, only
        # selkies restarts.
        setsid env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="${SHELL:-/bin/bash}" \
            LANG="${LANG:-C.UTF-8}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
            XDG_MENU_PREFIX=plasma- \
            XDG_DATA_DIRS="/usr/local/share:/usr/share:/var/lib/snapd/desktop" \
            XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true \
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            DISPLAY="$DISPLAY" XAUTHORITY= \
            QT_QUICK_BACKEND=software \
            /usr/bin/dbus-run-session -- /bin/sh -c \
            "python3 '$ROOT/tools/hold_dbus_name.py' org.bluez.obex & exec /usr/bin/startplasma-x11" \
            >"$ROOT/.plasma.log" 2>&1 &
    else
        echo "    Plasma session already running"
    fi
else
    echo "==> Detecting DISPLAY (mirroring existing session)"
    # Only a local display (":N") can be captured; a forwarded one (e.g. SSH's
    # "localhost:10.0") points at the client machine, not this desktop.
    if [ -n "${DISPLAY:-}" ] && [ "${DISPLAY#:}" = "$DISPLAY" ]; then
        echo "    ignoring non-local DISPLAY=$DISPLAY"
        DISPLAY=""
    fi
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
fi

echo "==> Starting selkies-gstreamer on port $PORT (encoder: $ENCODER)"
# Run this repo's source directly: PYTHONPATH puts ./src ahead of the copy
# installed inside the bundled runtime, so local changes always take effect.
export PYTHONPATH="$ROOT/src${PYTHONPATH:+:$PYTHONPATH}"
exec "$GSTREAMER_PATH/bin/python" -m selkies_gstreamer \
    --addr=0.0.0.0 \
    --port="$PORT" \
    --web_root="$WEB_DIST" \
    --enable_https="$ENABLE_HTTPS" \
    --basic_auth_password_enc="$BASIC_AUTH_PASSWORD_ENC" \
    --encoder="$ENCODER" \
    --framerate="$FRAMERATE" \
    --video_bitrate="$VIDEO_BITRATE" \
    --keyframe_distance="$KEYFRAME_DISTANCE" \
    --enable_resize="$RESIZE"
