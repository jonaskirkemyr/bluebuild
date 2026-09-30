#!/usr/bin/env bash

# Rebuilds the system CA bundle so the certificates shipped under
# files/system/usr/share/pki/ca-trust-source/anchors/ are trusted.
#
# Copying a file into anchors/ does nothing by itself: OpenSSL, GnuTLS, NSS and
# Java all read the *extracted* bundles under /etc/pki/ca-trust/extracted/, and
# only update-ca-trust writes those. On a mutable Fedora you run it by hand after
# the copy; here it has to run at build time, because nothing re-runs it on boot.
#
# /usr/share/pki/ca-trust-source/ rather than /etc/pki/ca-trust/source/ because
# the former is the distro-level location, which is what an image is. /etc stays
# free for certificates added on the machine itself, and those win on conflict.

set -euo pipefail

update-ca-trust extract
