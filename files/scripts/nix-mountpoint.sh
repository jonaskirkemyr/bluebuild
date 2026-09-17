#!/usr/bin/env bash

# Ships /nix as an empty directory so the Nix installer has somewhere to mount on
# an installed machine.
#
# This image deploys with composefs — /usr/lib/ostree/prepare-root.conf in the
# base image says:
#
#     [composefs]
#     enabled = yes
#     [sysroot]
#     readonly = true
#
# so / on a running machine is a genuinely read-only mount. nix-installer's
# ostree planner expects to create the mountpoint itself, with a
# nix-directory.service that runs `chattr -i /` and then `mkdir -p /nix`. That
# works on pre-composefs Silverblue, where / is merely flagged immutable and the
# flag can be cleared. Under composefs there is no writable / to un-flag, so it
# fails with EROFS. The message that reaches the screen is the misleading
# "Error saving receipt: read-only filesystem", because the rollback path then
# tries to write /nix/receipt.json and hits the same wall.
#
# Here, during the build, / is an ordinary writable container filesystem, so
# mkdir just works. `bootc container lint` accepts a top-level /nix.
#
# With the directory already present the installer needs nothing it cannot have:
# nix-directory.service carries ConditionPathExists=!/nix, so systemd skips it —
# and a skipped condition *satisfies* the Requires= from nix.mount rather than
# failing it — while nix.mount itself (ConditionPathIsDirectory=/nix) bind-mounts
# /var/home/nix over the directory as intended.
#
# The mount is set up by `ujust setup-nix`, not here. This script only reserves
# the mountpoint; a machine that never installs Nix just carries an empty
# directory.

set -oue pipefail

install -d -m 0755 /nix

# The bind mount hides whatever is underneath, so anything left here would be
# invisible at runtime while still costing space in every layer.
if [[ -n "$(ls -A /nix)" ]]; then
    echo "ERROR: /nix is not empty; a bind mount over it would hide these files." >&2
    ls -A /nix >&2
    exit 1
fi

echo "/nix mountpoint reserved (empty). ujust setup-nix will mount /var/home/nix over it."
