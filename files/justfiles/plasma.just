# Recipes for the KDE Plasma settings that nix-config cannot own. Run `ujust` with
# no arguments to list every recipe.
#
# `configure-plasma` is the one place for "how I want System Settings to look on a
# machine". Add a function for each new setting and call it from the bottom; every
# step is idempotent, so the recipe can be re-run whenever it changes.

# Apply my System Settings tweaks (touchpad, power management) to this machine
configure-plasma:
    #!/usr/bin/env bash
    set -euo pipefail

    # ---- Input ----------------------------------------------------------------

    # KDE keeps touchpad settings per device, in kcminputrc under
    # [Libinput][<vendor>][<product>][<name>] with the ids in decimal, and has no
    # "all touchpads" setting. nix-config therefore cannot declare it for hardware
    # it has not seen, which is why this reads the devices of the machine at hand.
    #
    # /proc/bus/input/devices has one blank-line-separated block per device:
    #   I: Bus=0018 Vendor=04f3 Product=3195 Version=0100
    #   N: Name="ELAN0676:00 04F3:3195 Touchpad"
    #   H: Handlers=mouse1 event7
    # The awk emits one tab-separated line per touchpad (ids in hex).
    list_touchpads() {
        awk -v RS= -v FS='\n' '
            /Name="[^"]*[Tt]ouchpad"/ {
                vendor = product = name = event = ""
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^I:/) {
                        match($i, /Vendor=[0-9a-fA-F]+/);  vendor = substr($i, RSTART + 7, RLENGTH - 7)
                        match($i, /Product=[0-9a-fA-F]+/); product = substr($i, RSTART + 8, RLENGTH - 8)
                    } else if ($i ~ /^N:/) {
                        name = $i; sub(/^N: Name="/, "", name); sub(/"$/, "", name)
                    } else if ($i ~ /^H:/ && match($i, /event[0-9]+/)) {
                        event = substr($i, RSTART, RLENGTH)
                    }
                }
                printf "%s\t%s\t%s\t%s\n", vendor, product, name, event
            }' /proc/bus/input/devices
    }

    natural_scrolling() {
        local value="$1" vendor product name event found=0
        while IFS=$'\t' read -r vendor product name event; do
            found=1
            kwriteconfig6 --file kcminputrc \
                --group Libinput --group "$((16#$vendor))" --group "$((16#$product))" --group "$name" \
                --key NaturalScroll "$value"
            # Without this the setting waits for the next login. KWin exposes each
            # device on D-Bus; failing is fine, the file is already written.
            if [[ -n "$event" ]]; then
                qdbus-qt6 org.kde.KWin "/org/kde/KWin/InputDevice/$event" \
                    org.kde.KWin.InputDevice.naturalScroll "$value" >/dev/null 2>&1 || true
            fi
            echo "touchpad: natural scrolling $value ($name)"
        done < <(list_touchpads)
        if [[ "$found" -eq 0 ]]; then
            echo "touchpad: none found, skipped"
        fi
    }

    # ---- Power management -----------------------------------------------------

    # One powerdevilrc profile. Arguments are minutes, except dim which is seconds
    # (the KCM's minimum for it is 20 s, and the battery profile wants 1 minute).
    # Section is AC or Battery. Action 1 is "sleep" (powerdevilenums.h).
    #
    # The charge limit (start below 80 %, stop at 90 %) is not here: it is written to
    # sysfs by a root helper, so the image sets it with a udev rule instead
    # (files/system/usr/lib/udev/rules.d/90-battery-charge-limit.rules).
    power_profile() {
        local section="$1" sleep_min="$2" dim_sec="$3" off_min="$4" off_locked_min="$5"
        local file=powerdevilrc
        kwriteconfig6 --file "$file" --group "$section" --group SuspendAndShutdown \
            --key AutoSuspendAction 1
        kwriteconfig6 --file "$file" --group "$section" --group SuspendAndShutdown \
            --key AutoSuspendIdleTimeoutSec "$((sleep_min * 60))"
        kwriteconfig6 --file "$file" --group "$section" --group Display \
            --key DimDisplayWhenIdle true
        kwriteconfig6 --file "$file" --group "$section" --group Display \
            --key DimDisplayIdleTimeoutSec "$dim_sec"
        kwriteconfig6 --file "$file" --group "$section" --group Display \
            --key TurnOffDisplayIdleTimeoutSec "$((off_min * 60))"
        kwriteconfig6 --file "$file" --group "$section" --group Display \
            --key TurnOffDisplayIdleTimeoutWhenLockedSec "$((off_locked_min * 60))"
        echo "power: $section — sleep ${sleep_min} min, dim ${dim_sec} s, screen off ${off_min} min (${off_locked_min} min locked)"
    }

    reload_power() {
        qdbus-qt6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement \
            org.kde.Solid.PowerManagement.reparseConfiguration >/dev/null 2>&1 ||
            echo "power: could not reload PowerDevil, log out and back in to apply"
    }

    # ---- What I want ----------------------------------------------------------

    natural_scrolling true

    #             section  sleep  dim(s)  off  off-when-locked
    power_profile AC       60     900     30   2
    power_profile Battery  15     60      2    1
    reload_power
