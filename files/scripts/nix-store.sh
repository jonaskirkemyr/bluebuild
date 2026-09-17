#!/usr/bin/env bash

# Teaches SELinux that /var/lib/nix is /nix.
#
# Nix comes from Fedora's own RPMs (see the dnf module in recipes/recipe.yml), which
# ship /nix inside the image. The image root is read-only under composefs, so
# nix.mount bind-mounts /var/lib/nix over it — see
# files/system/usr/lib/systemd/system/nix.mount for why.
#
# A bind mount does not relabel anything. SELinux labels live in the inode's xattrs,
# and a newly created file takes its type from its parent *directory*, not from the
# path it happens to be reachable at. So without this, everything in the store would
# be var_lib_t, while the same store on an ordinary Fedora install is default_t —
# there is no /nix rule in the targeted policy, so /nix falls through to the `/.*`
# catch-all. Diverging from that puts this machine on a path nobody else runs.
#
# `semanage fcontext -a -e` declares a path equivalency, which is precisely the tool
# for a bind-mount source: it makes matchpathcon and restorecon treat
# /var/lib/nix/store/... exactly as they would /nix/store/..., so
# nix-store-dir.service's restorecon gives the directory default_t, every store path
# created under it inherits that, and a full filesystem relabel (fixfiles -F) keeps
# the store as it was instead of rewriting it to var_lib_t.
#
# It writes one line to /etc/selinux/targeted/contexts/files/file_contexts.subs.
# That is under /etc, which ostree merges three ways, so it reaches machines that are
# already installed as well as fresh ones.

set -oue pipefail

SUBS="/etc/selinux/targeted/contexts/files/file_contexts.subs"

# Fail the build rather than the boot if the package set ever stops shipping these.
for DIR in /nix /nix/store /nix/var; do
    if [[ ! -d "$DIR" ]]; then
        echo "ERROR: $DIR is missing. Is 'nix' still in the dnf module?" >&2
        exit 1
    fi
done

if grep -qs '^/var/lib/nix /nix$' "$SUBS"; then
    echo "SELinux equivalency /var/lib/nix -> /nix already present."
else
    semanage fcontext -a -e /nix /var/lib/nix
fi

# `matchpathcon` answers from the policy, not from what is on disk, so this checks
# the rule rather than the labels of this container's filesystem.
GOT="$(matchpathcon -n /var/lib/nix/store/zzz-example/bin/example)"
WANT="$(matchpathcon -n /nix/store/zzz-example/bin/example)"
if [[ "$GOT" != "$WANT" ]]; then
    echo "ERROR: equivalency did not take." >&2
    echo "  /var/lib/nix/store/... -> $GOT" >&2
    echo "  /nix/store/...         -> $WANT" >&2
    exit 1
fi

echo "Nix store: /var/lib/nix labelled as /nix ($WANT); nix.mount binds it onto /nix."
