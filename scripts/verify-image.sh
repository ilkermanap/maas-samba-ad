#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# verify-image.sh - checks that the produced MAAS tarball contains what it should.
#
# Kullanim:  ./scripts/verify-image.sh build/samba-ad-dc.tar.gz
#
set -uo pipefail

IMG="${1:-}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "Usage: $0 <imaj.tar.gz>" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Imaj: $IMG ($(du -h "$IMG" | cut -f1))"
echo "==> Icerik listesi cikariliyor..."
tar tzf "$IMG" > "$TMP/list" || { echo "HATA: arsiv okunamadi"; exit 1; }
echo "    $(wc -l < "$TMP/list") giris"

pass=0; fail=0
have()    { grep -qx "\./$1" "$TMP/list" || grep -q "^\./$1$" "$TMP/list"; }
present() { grep -q "^\./$1" "$TMP/list"; }

check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        printf '  [ OK ] %s\n' "$desc"; pass=$((pass+1))
    else
        printf '  [FAIL] %s\n' "$desc"; fail=$((fail+1))
    fi
}

echo
echo "=== Files that must be present ==="
check "adc-maas-init"                        'present "usr/local/sbin/adc-maas-init"'
check "adc-sysvol-sync"                      'present "usr/local/sbin/adc-sysvol-sync"'
check "adc-maas.conf"                        'present "etc/adc-maas/adc-maas.conf"'
check "image-info"                           'present "etc/adc-maas/image-info"'
check "adc-maas-init.service"                'present "etc/systemd/system/adc-maas-init.service"'
check "unit enabled for multi-user.target"   'present "etc/systemd/system/multi-user.target.wants/adc-maas-init.service"'
check "adc-sysvol-sync.timer"                'present "etc/systemd/system/adc-sysvol-sync.timer"'
check "curtin-hooks"                         'present "curtin/curtin-hooks"'
check "samba daemon"                         'present "usr/sbin/samba"'
check "samba-tool"                           'present "usr/bin/samba-tool"'
check "winbindd"                             'present "usr/sbin/winbindd"'
check "smbclient"                            'present "usr/bin/smbclient"'
check "chronyd (Kerberos needs the clock)"   'present "usr/sbin/chronyd"'
check "rsync (SYSVOL replication)"           'present "usr/bin/rsync"'
check "cloud-init"                           'present "usr/bin/cloud-init"'
check "generic kernel (not the cloud one)"   'grep -qE "^\\./boot/vmlinuz-.*-(amd64|arm64)$" "$TMP/list"'

echo
echo "=== Files that must NOT be present ==="
check "no smb.conf (image carries no domain)"  '! present "etc/samba/smb.conf"'
check "no directory database (sam.ldb)"        '! present "var/lib/samba/private/sam.ldb"'
check "no secrets.tdb"                         '! present "var/lib/samba/private/secrets.tdb"'
check "no krb5.keytab"                         '! present "etc/krb5.keytab"'
check "no iSCSI initiator name"                '! present "etc/iscsi/initiatorname.iscsi"'
check "no SSH host keys"                       '! grep -qE "^\\./etc/ssh/ssh_host_.*_key$" "$TMP/list"'
check "networking.service NOT enabled"         '! present "etc/systemd/system/multi-user.target.wants/networking.service"'
check "no interfaces.new"                      '! present "etc/network/interfaces.new"'
check "no cloud-only kernel"                   '! grep -qE "^\\./boot/vmlinuz-.*-cloud-(amd64|arm64)$" "$TMP/list"'

echo
echo "=== Kernel ==="
if grep -qE '^\./boot/vmlinuz-.*-(amd64|arm64)$' "$TMP/list"; then
    printf '  [ OK ] generic kernel: %s\n' "$(grep -oE 'vmlinuz-[^ ]*' "$TMP/list" | head -1)"
    pass=$((pass+1))
else
    printf '  [FAIL] no generic (non-cloud) kernel under /boot\n'; fail=$((fail+1))
fi

echo
echo "==> Ayiklanan dosya icerikleri"
tar xzf "$IMG" -C "$TMP" \
    ./usr/local/sbin/adc-maas-init \
    ./etc/adc-maas/adc-maas.conf ./etc/adc-maas/image-info 2>/dev/null

tar xzf "$IMG" -C "$TMP" ./etc/network/interfaces 2>/dev/null
if [ -f "$TMP/etc/network/interfaces" ]; then
    echo "--- /etc/network/interfaces ---"
    sed 's/^/    /' "$TMP/etc/network/interfaces"
    if grep -qE '^\s*(auto|iface)\s+(?!lo)' "$TMP/etc/network/interfaces" 2>/dev/null \
       || grep -qE '^[[:space:]]*iface[[:space:]]+[^l ]' "$TMP/etc/network/interfaces"; then
        printf '  [FAIL] interfaces dosyasinda build VM artigi arayuz var\n'; fail=$((fail+1))
    else
        printf '  [ OK ] interfaces yalnizca loopback iceriyor\n'; pass=$((pass+1))
    fi
fi

if [ -f "$TMP/etc/adc-maas/image-info" ]; then
    echo "--- image-info ---"
    sed 's/^/    /' "$TMP/etc/adc-maas/image-info"
fi

if [ -x "$TMP/usr/local/sbin/adc-maas-init" ]; then
    printf '  [ OK ] adc-maas-init is executable\n'; pass=$((pass+1))
else
    printf '  [FAIL] adc-maas-init is not executable\n'; fail=$((fail+1))
fi

echo
echo "==> Result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
