#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Moves the built image into dist/ under a release-friendly name and writes the
# checksum plus the corresponding-source offer that has to accompany a binary
# distribution of GPL/AGPL software.
#
#   assemble-artifacts.sh <samba-version>
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?samba version required}"
OUT=$(make -s print-var VAR=OUTPUT)
ARCH=$(make -s print-var VAR=ARCH)
[ -f "$OUT" ] || { echo "built image not found: $OUT" >&2; exit 1; }

# Named after what it is - a MAAS image carrying a Samba AD domain
# controller. Nothing here is a Microsoft or Samba product.
NAME="maas-image-samba-ad-${VERSION}-${ARCH}.tar.gz"

rm -rf dist && mkdir -p dist
mv "$OUT" "dist/${NAME}"
( cd dist && sha256sum "$NAME" > "${NAME}.sha256" )

tar xzf "dist/${NAME}" -O ./etc/adc-maas/image-info > dist/image-info.txt 2>/dev/null \
  || echo "(no image-info found)" > dist/image-info.txt

DEB_VER=$(make -s print-var VAR=DEBIAN_VERSION)
DEB_SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
REPO_URL="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}"

{
    echo "# Corresponding source"
    echo
    echo "This image is an unmodified installation of packages from the archives listed"
    echo "below. No package was patched. What is ours is the selection and the"
    echo "configuration, and that is the entire content of the repository linked below."
    echo
    echo "Written offer, per GPLv2 section 3 and GPLv3 section 6: the complete"
    echo "corresponding source for every package in this image is available from the"
    echo "archive it was installed from, at the versions recorded in the image's own"
    echo "package database (\`/var/lib/dpkg/status\`)."
    echo
    echo "| Component | Source |"
    echo "|---|---|"
    echo "| Debian ${DEB_VER} \"${DEB_SUITE}\" | <https://deb.debian.org/debian> — \`apt-get source <pkg>\` |"
    echo "| Build recipe | <${REPO_URL}> |"
    echo
    echo "Samba is GPLv3+; the Debian source package carries the full terms."
    echo
    echo "## Image metadata"
    echo
    echo '```'
    cat dist/image-info.txt
    echo '```'
} > dist/SOURCES.md

ls -lh dist/
