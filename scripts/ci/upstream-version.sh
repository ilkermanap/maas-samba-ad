#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prints the newest samba version in the configured Debian suite.
set -euo pipefail
cd "$(dirname "$0")/../.."

SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
ARCH=$(make -s print-var VAR=ARCH)

VER=$(curl -fsS "http://deb.debian.org/debian/dists/${SUITE}/main/binary-${ARCH}/Packages.gz" \
      | gunzip \
      | awk '/^Package: samba$/{p=1; next} p && /^Version: /{print $2; p=0}' \
      | sort -V | tail -1)
[ -n "$VER" ] || { echo "samba not found in Debian ${SUITE}" >&2; exit 1; }
printf '%s\n' "$VER"
