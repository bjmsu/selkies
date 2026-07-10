#!/bin/bash
# Trim ~440MB of unused content from the bundled GStreamer runtime before
# committing it. Nothing is deleted: everything is MOVED (with relative paths
# preserved) into a backup dir under /tmp, so a full restore is one rsync.
#
#   restore:  rsync -a "$BACKUP/" ~/project/selkies/gstreamer/
#
# NOTE: /tmp is cleared on reboot — confirm the runtime still works BEFORE
# rebooting, or move the backup somewhere persistent.
set -euo pipefail

GST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gstreamer"
BACKUP="/tmp/gstreamer-trim-backup-$(date +%Y%m%d-%H%M%S)"

[ -d "$GST" ] || { echo "runtime not found at $GST" >&2; exit 1; }
mkdir -p "$BACKUP"

# Relative paths to remove. Verified unused by selkies:
#  - libgstrswebrtc.so: Rust webrtcsink/webrtcsrc — selkies uses C webrtcbin
#    (libgstwebrtc.so); also breaks GitHub's 100MB file limit.
#  - gst-webrtc-signalling-server: companion of webrtcsink, selkies has its own.
#  - docs/share doc/man/info/locale/gir-1.0/terminfo/X11: docs, translations,
#    binding sources, and data the system already provides.
#  - lib/*.a: static libraries, never loaded at runtime.
#  - conda-meta, fonts, compiler cruft: conda packaging leftovers.
ITEMS=(
    lib/gstreamer-1.0/libgstrswebrtc.so
    bin/gst-webrtc-signalling-server
    bin/py-spy
    bin/x86_64-conda-linux-gnu-ld
    bin/pcre2test
    docs
    share/locale
    share/gir-1.0
    share/doc
    share/man
    share/info
    share/terminfo
    share/X11
    share/gtk-doc
    conda-meta
    fonts
    man
    sbin
    var
    compiler_compat
    x86_64-conda-linux-gnu
    x86_64-conda_cos6-linux-gnu
    # round 2: file-count reduction for the git repo
    share/zoneinfo
    include/python3.12
    include/unicode
    include/X11
    include/tcl8.6
    include/tk8.6
    lib/tcl8.6
    lib/tk8.6
    lib/tclConfig.sh
    lib/tkConfig.sh
    lib/python3.12/idlelib
    lib/python3.12/lib2to3
    lib/python3.12/tkinter
    lib/python3.12/turtledemo
)

moved=0
for rel in "${ITEMS[@]}"; do
    src="$GST/$rel"
    [ -e "$src" ] || continue
    mkdir -p "$BACKUP/$(dirname "$rel")"
    mv "$src" "$BACKUP/$rel"
    moved=$((moved+1))
    echo "  moved $rel"
done

# Static libraries scattered in lib/
find "$GST/lib" -maxdepth 1 -name '*.a' | while read -r f; do
    mkdir -p "$BACKUP/lib"
    mv "$f" "$BACKUP/lib/"
    echo "  moved lib/$(basename "$f")"
done

# Stale plugin registry cache (rebuilt automatically on next start)
rm -f "$GST/.gst-registry.bin"

echo
echo "moved $moved entries + static libs"
echo "backup:  $BACKUP ($(du -sh "$BACKUP" | cut -f1))"
echo "runtime: $GST ($(du -sh "$GST" | cut -f1))"
echo
echo "restore with:  rsync -a '$BACKUP/' '$GST/'"
