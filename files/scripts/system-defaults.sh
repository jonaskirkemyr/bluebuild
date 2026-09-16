#!/usr/bin/env bash

# Bakes locale, console/X11 keymap and timezone into the image so the first boot
# is silent.
#
# The base image ships none of /etc/locale.conf, /etc/vconsole.conf or
# /etc/localtime, and Kinoite has no graphical setup wizard — so
# systemd-firstboot.service (enabled upstream, Description="Initial Setup") runs
# `--prompt-locale --prompt-keymap-auto --prompt-timezone` on a VT and asks. Its
# man page: "If a setting is already initialized, it will not be overwritten and
# the user will not be prompted for the setting." Writing the three files here is
# therefore all it takes; the unit still runs on first boot, finds everything set,
# and exits without asking anything.
#
# These are only *defaults*. /etc is a 3-way merge on rpm-ostree, so changing the
# timezone or layout in System Settings later sticks and image updates won't
# clobber it.

set -oue pipefail

LOCALE="en_US.UTF-8" # English system messages; keeps errors greppable
KEYMAP="no"          # Norwegian layout, console + X11/Wayland
TIMEZONE="Europe/Oslo"

# Split out from LOCALE on purpose. en_US means 12-hour am/pm, which is the only
# reason the clock reads "02:05:00 PM"; the time format comes from LC_TIME, not
# LANG. Overriding just this one category buys a 24-hour clock everywhere —
# including the SDDM login screen, before any user config exists — while system
# messages stay English.
LC_TIME_LOCALE="nb_NO.UTF-8"

# using the tool itself rather than hand-writing the files: it generates the
# XKBLAYOUT/XKBMODEL keys in vconsole.conf and the relative /etc/localtime symlink
# exactly as systemd expects them. It talks to localed over D-Bus for a
# nice-to-have lookup and logs a harmless failure at build time (no PID 1 in a
# container); the files are written regardless and it still exits 0.
systemd-firstboot \
    --root=/ \
    --locale="${LOCALE}" \
    --keymap="${KEYMAP}" \
    --timezone="${TIMEZONE}"

# systemd-firstboot only ever writes LANG= and LC_MESSAGES=, so LC_TIME is
# appended by hand. locale.conf(5) accepts every LC_* category, and glibc gives a
# single category set here precedence over LANG.
echo "LC_TIME=${LC_TIME_LOCALE}" >>/etc/locale.conf

# a locale missing from the image would silently fall back to C, so check
if ! LC_ALL="${LC_TIME_LOCALE}" locale >/dev/null 2>&1; then
    echo "ERROR: locale ${LC_TIME_LOCALE} is not available in this image." >&2
    exit 1
fi

# fail the build rather than ship an image that still prompts
for f in /etc/locale.conf /etc/vconsole.conf /etc/localtime; do
    if [[ ! -e "${f}" ]]; then
        echo "ERROR: ${f} was not written; first boot would still prompt." >&2
        exit 1
    fi
done

echo "System defaults baked in: LANG=${LOCALE} LC_TIME=${LC_TIME_LOCALE} KEYMAP=${KEYMAP} TZ=${TIMEZONE}"
