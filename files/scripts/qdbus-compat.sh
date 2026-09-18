#!/usr/bin/env bash

# Links /usr/bin/qdbus to Fedora's Qt6 build of it.
#
# Fedora names the binary after the Qt version it belongs to — qt6-qttools ships
# /usr/bin/qdbus-qt6, qt5-qttools /usr/bin/qdbus-qt5 — so the two can be installed
# side by side. Nothing is called plain `qdbus`. That is fine for Fedora's own
# packages, which all call the versioned name, and a trap for anything written for
# a distro that ships one Qt.
#
# plasma-manager (layer 2, the nix-config repo) is exactly that. Every one of its
# desktop scripts — panels, widgets, wallpaper, desktop containments — is applied
# by one line in its modules/startup.nix:
#
#   qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$(cat ...)"
#
# unqualified, because on NixOS `qdbus` is on PATH. On Fedora that is "command not
# found", every desktop script fails, and *none* of the panel or wallpaper config
# is ever applied. The failure is close to invisible: the generated scripts wrap
# the call in `trap 'success=0' ERR` and only write their
# ~/.local/share/plasma-manager/last_run_* marker on success, so they fail quietly
# and retry at the next login, forever. Raw ini keys (`configFile`, `shortcuts`)
# still land, which makes it look like plasma-manager is working.
#
# A symlink rather than a wrapper script so `ls -l /usr/bin/qdbus` says what this
# is, and so it cannot drift from the real binary's behaviour.

set -oue pipefail

LINK="/usr/bin/qdbus"

# Fail the build rather than the login if a future base image renames this. The
# dnf module installs qt6-qttools explicitly so this cannot go missing quietly.
TARGET=""
for CANDIDATE in /usr/bin/qdbus-qt6 /usr/lib64/qt6/bin/qdbus; do
    if [[ -x "$CANDIDATE" ]]; then
        TARGET="$CANDIDATE"
        break
    fi
done
if [[ -z "$TARGET" ]]; then
    echo "ERROR: no Qt6 qdbus found. Is 'qt6-qttools' still in the dnf module?" >&2
    echo "       Checked /usr/bin/qdbus-qt6 and /usr/lib64/qt6/bin/qdbus." >&2
    exit 1
fi

# If Fedora ever ships a real /usr/bin/qdbus, get out of its way: an unowned file
# where a package wants one is how `rpm-ostree install` fails later.
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "$LINK already exists as a real file — leaving it alone."
    exit 0
fi

ln -sfn "$TARGET" "$LINK"
echo "qdbus: $LINK -> $TARGET (plasma-manager calls it unqualified)."
