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
#   1. samba in the Debian suite differs from the published image
#   2. the kernel package differs — kernel security fixes do not bump samba
#   3. the newest release is older than max-age-days — most Debian security
#      updates touch neither, so without a floor an image could sit unchanged
#      for months while its openssl and glibc went stale
#
# Requires GITEA_API and GITEA_TOKEN in the environment.
set -euo pipefail
cd "$(dirname "$0")/../.."

MAX_AGE_DAYS="${1:-30}"
: "${GITEA_API:?GITEA_API required}"
: "${GITEA_TOKEN:?GITEA_TOKEN required}"

SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
ARCH=$(make -s print-var VAR=ARCH)

# Newest version of each package we care about, in one pass over the index.
PKGS=$(curl -fsS "http://deb.debian.org/debian/dists/${SUITE}/main/binary-${ARCH}/Packages.gz" | gunzip)
newest() {
    printf '%s\n' "$PKGS" \
      | awk -v want="$1" '$1=="Package:" && $2==want {p=1; next} p && $1=="Version:" {print $2; p=0}' \
      | sort -V | tail -1
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
    PREV_KERNEL=$(printf '%s' "$INFO" | awk -F= '$1=="kernel"{print $2}')
fi
echo "published: samba=${PREV_SAMBA:-<none>} kernel=${PREV_KERNEL:-<none>}" >&2

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
elif [ "$UP_SAMBA" != "$PREV_SAMBA" ]; then
    BUILD=yes; REASON="samba ${PREV_SAMBA} -> ${UP_SAMBA}"
elif [ "$UP_KERNEL" != "$PREV_KERNEL" ]; then
    BUILD=yes; REASON="kernel ${PREV_KERNEL} -> ${UP_KERNEL}"
elif [ "$AGE_DAYS" -ge "$MAX_AGE_DAYS" ]; then
    BUILD=yes; REASON="image is ${AGE_DAYS} days old (limit ${MAX_AGE_DAYS}) — picking up Debian updates"
fi
echo "decision: ${BUILD} (${REASON})" >&2

printf 'build=%s\n'   "$BUILD"
# Debian versions carry epochs and tildes; a tag cannot.
SAFE_VER=$(printf '%s' "$UP_SAMBA" | sed 's/^[0-9]*://; s/[^A-Za-z0-9._-]/-/g')
printf 'tag=%s\n'     "samba-${SAFE_VER}-$(date -u +%Y%m%d)"
printf 'version=%s\n' "$SAFE_VER"
printf 'kernel=%s\n'  "$UP_KERNEL"
printf 'reason=%s\n'  "$REASON"
