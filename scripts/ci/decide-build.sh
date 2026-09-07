#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Decides whether a rebuild is worth doing, and prints the decision as
# key=value lines suitable for $GITHUB_OUTPUT.
#
#   decide-build.sh [max-age-days]     (default 30)
#
# A rebuild happens when any of these is true:
#
#   1. samba in the Debian archive is newer than the published image
#   2. the kernel package is newer — kernel security fixes do not bump samba
#   3. the newest release is older than max-age-days — most Debian security
#      updates touch neither, so without a floor an image could sit unchanged
#      for months while its openssl and glibc went stale
#
# Two things this gets wrong if you are not careful, both of which made it
# rebuild every single night:
#
#   * The image installs from trixie, trixie-updates AND trixie-security.
#     Reading only trixie/main reports samba 2:4.22.10+dfsg-0+deb13u1 while the
#     image contains ...u2 from security, so the versions never match.
#   * /boot/vmlinuz-* yields an ABI string such as 6.12.107+deb13-amd64, which
#     is a package-name suffix, not a version. Comparing it against the
#     archive's 6.12.107-1 never matches either. Images now also record
#     kernel_version, which is directly comparable.
#
# Versions are compared with dpkg rather than sort -V, which mishandles epochs
# and tildes, and with "gt" rather than "!=" so an image that is somehow ahead
# of the archive does not trigger an endless rebuild loop.
#
# Requires GITEA_API and GITEA_TOKEN in the environment.
set -euo pipefail
cd "$(dirname "$0")/../.."

MAX_AGE_DAYS="${1:-30}"
: "${GITEA_API:?GITEA_API required}"
: "${GITEA_TOKEN:?GITEA_TOKEN required}"

SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
ARCH=$(make -s print-var VAR=ARCH)

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
INDEX="$TMP/packages"

# $1 url, $2 "required"|"optional". Appends the decompressed index to $INDEX.
fetch_index() {
    local url=$1 need=$2
    if curl -fsS "$url" 2>/dev/null | xz -dc >> "$INDEX" 2>/dev/null; then
        return 0
    fi
    if [ "$need" = required ]; then
        echo "cannot read package index: $url" >&2
        exit 1
    fi
    echo "note: no index at $url (skipping)" >&2
}

: > "$INDEX"
fetch_index "http://deb.debian.org/debian/dists/${SUITE}/main/binary-${ARCH}/Packages.xz"                   required
fetch_index "http://deb.debian.org/debian-security/dists/${SUITE}-security/main/binary-${ARCH}/Packages.xz" required
fetch_index "http://deb.debian.org/debian/dists/${SUITE}-updates/main/binary-${ARCH}/Packages.xz"           optional

# Highest version of a package across every suite we merged.
newest() {
    local best="" v
    while read -r v; do
        [ -n "$v" ] || continue
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done < <(awk -v want="$1" '
        $1=="Package:" && $2==want {p=1; next}
        p && $1=="Version:" {print $2; p=0}' "$INDEX")
    printf '%s\n' "$best"
}

UP_SAMBA=$(newest samba)
UP_KERNEL=$(newest "linux-image-${ARCH}")
[ -n "$UP_SAMBA" ]  || { echo "samba not found in Debian ${SUITE}" >&2; exit 1; }
[ -n "$UP_KERNEL" ] || { echo "linux-image-${ARCH} not found" >&2; exit 1; }

echo "upstream: samba=${UP_SAMBA} linux-image=${UP_KERNEL}" >&2

# What the newest published release actually contains. image-info.txt is a few
# hundred bytes and is published with every release, so this needs no guessing
# from tag names.
LATEST=$(curl -fsS -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_API}/releases?limit=1")
INFO_URL=$(printf '%s' "$LATEST" | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r:
    for a in r[0].get("assets", []):
        if a["name"] == "image-info.txt":
            print(a["browser_download_url"]); break
')
CREATED=$(printf '%s' "$LATEST" | python3 -c '
import json, sys
r = json.load(sys.stdin); print(r[0]["created_at"] if r else "")')

PREV_SAMBA="" PREV_KERNEL=""
if [ -n "$INFO_URL" ]; then
    INFO=$(curl -fsSL "$INFO_URL" || true)
    PREV_SAMBA=$(printf '%s' "$INFO"  | awk -F= '$1=="samba"{print $2}')
    PREV_KERNEL=$(printf '%s' "$INFO" | awk -F= '$1=="kernel_version"{print $2}')
    [ "$PREV_KERNEL" = unknown ] && PREV_KERNEL=""
fi
echo "published: samba=${PREV_SAMBA:-<none>} kernel_version=${PREV_KERNEL:-<none>}" >&2

AGE_DAYS=99999
if [ -n "$CREATED" ]; then
    AGE_DAYS=$(CREATED="$CREATED" python3 -c '
import datetime, os
c = datetime.datetime.fromisoformat(os.environ["CREATED"].replace("Z", "+00:00"))
print((datetime.datetime.now(datetime.timezone.utc) - c).days)')
    echo "newest release is ${AGE_DAYS} day(s) old" >&2
fi

BUILD=no
REASON="up to date"
if [ -z "$PREV_SAMBA" ]; then
    BUILD=yes; REASON="no published image yet"
elif dpkg --compare-versions "$UP_SAMBA" gt "$PREV_SAMBA"; then
    BUILD=yes; REASON="samba ${PREV_SAMBA} -> ${UP_SAMBA}"
elif [ -n "$PREV_KERNEL" ] && dpkg --compare-versions "$UP_KERNEL" gt "$PREV_KERNEL"; then
    BUILD=yes; REASON="kernel ${PREV_KERNEL} -> ${UP_KERNEL}"
elif [ "$AGE_DAYS" -ge "$MAX_AGE_DAYS" ]; then
    BUILD=yes; REASON="image is ${AGE_DAYS} days old (limit ${MAX_AGE_DAYS}) — picking up Debian updates"
fi
# Releases published before image-info carried kernel_version cannot be checked
# for kernel changes; say so rather than letting the gap pass unnoticed.
if [ -n "$PREV_SAMBA" ] && [ -z "$PREV_KERNEL" ]; then
    echo "note: published image records no kernel_version; kernel check skipped" >&2
fi
echo "decision: ${BUILD} (${REASON})" >&2

printf 'build=%s\n'   "$BUILD"
# Debian versions carry epochs and tildes; a tag cannot.
SAFE_VER=$(printf '%s' "$UP_SAMBA" | sed 's/^[0-9]*://; s/[^A-Za-z0-9._-]/-/g')
printf 'tag=%s\n'     "samba-${SAFE_VER}-$(date -u +%Y%m%d)"
printf 'version=%s\n' "$SAFE_VER"
printf 'kernel=%s\n'  "$UP_KERNEL"
printf 'reason=%s\n'  "$REASON"
