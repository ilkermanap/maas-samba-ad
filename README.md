# maas-samba-ad

Build a Debian image that [MAAS](https://maas.io) can deploy to bare metal as an
**Active Directory domain controller**, with first-boot automation that either creates
a new domain or joins an existing one — without anyone logging in.

The domain controller is [Samba](https://www.samba.org/) in AD DC mode. To a Windows
client it is an Active Directory domain: same Kerberos, same LDAP, same Group Policy,
same `net use`, same domain join.

> Verified end to end on real infrastructure: two domain controllers deployed from
> MAAS, replicating, with a Windows Server 2025 machine joined to the domain. See
> [Verified status](#verified-status) for exactly what was and was not tested.

---

## Table of contents

- [If Active Directory is new to you](#if-active-directory-is-new-to-you)
- [What "highly available" means here](#what-highly-available-means-here)
- [The SYSVOL problem](#the-sysvol-problem)
- [What Samba does not do](#what-samba-does-not-do)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Deploying a domain](#deploying-a-domain)
- [Configuration reference](#configuration-reference)
- [Operating the domain](#operating-the-domain)
- [Build configuration](#build-configuration)
- [Traps this image works around](#traps-this-image-works-around)
- [Verified status](#verified-status)
- [Licensing](#licensing)

---

## If Active Directory is new to you

Skip this if it isn't.

**There is no "primary" and "backup" domain controller.** That is Windows NT 4
terminology, retired in 2000. In Active Directory every DC holds a full, writable copy
of the directory and they replicate to each other. Any DC can service any logon.

What *does* live on exactly one DC at a time are the five **FSMO roles** — small
coordination duties such as allocating blocks of security identifiers. One of them is
called "PDC Emulator", which is where the old name survives and where most of the
confusion comes from. Losing the DC that holds them does not cost you the domain; you
seize the roles onto another DC and carry on.

So this image has two modes, and they map to the real distinction:

| Mode | What it does |
|---|---|
| `AD_MODE=provision` | Creates the domain. The first DC, and initially the FSMO holder |
| `AD_MODE=join` | Joins the existing domain as another equal DC |

**A domain is not one service.** These have to work together, and all of them except
the clock come from the single `samba` daemon:

| Piece | Why it matters |
|---|---|
| **LDAP** | The directory itself: users, groups, computers, policy links |
| **Kerberos** | Issues the tickets clients actually authenticate with |
| **DNS** | Clients find domain controllers through SRV records. AD without working DNS does not function at all — this is the single most common cause of a broken domain |
| **SMB** | Serves `SYSVOL` and `NETLOGON`, the shares Group Policy and logon scripts live in |
| **Time** | Kerberos refuses tickets when clocks differ by more than five minutes. The symptom is logins failing for no visible reason |

The image installs and wires up all of them.

**Names you have to choose.** Two, and they are awkward to change later:

- **Realm** — your DNS domain in uppercase, e.g. `AD.EXAMPLE.COM`. Use a domain you
  control. Do not use your public web domain, and never a bare `.local` (it collides
  with mDNS).
- **NetBIOS name** — the short legacy form, e.g. `EXAMPLE`. Uppercase, at most 15
  characters, no dots. Conventionally the realm's first label.

**Passwords.** Active Directory enforces complexity by default: at least seven
characters, and three of upper case, lower case, digit, symbol. A weak
`AD_ADMIN_PASSWORD` makes provisioning fail with an error that does not say so.

---

## What "highly available" means here

Availability in an AD domain comes from having more than one DC, not from clustering
anything. Concretely:

1. **At least two DCs.** Two survives losing one. Three is better, because with two you
   have no majority when one is down and some operations get cautious.
2. **Each DC runs DNS**, serving the same AD-integrated zones. This image does that
   automatically — every DC answers for the domain.
3. **Clients must be told about both.** Hand out both DC addresses as DNS servers over
   DHCP. A client that only knows one DC has no redundancy no matter how many you run.
   In MAAS that is the subnet's DNS server list.
4. **Time comes from the DCs.** Set `AD_NTP_ALLOW` so members can use them.
5. **SYSVOL has to be replicated.** This is the part that does not happen by itself —
   see below.

The FSMO roles sit on the first DC. If it dies permanently you seize them; the domain
keeps authenticating in the meantime.

---

## The SYSVOL problem

**Read this before relying on the result.**

`SYSVOL` is the share holding Group Policy objects and logon scripts. Windows replicates
it between DCs using DFS-R. **Samba implements neither DFS-R nor its predecessor FRS**,
so a policy created on one DC never reaches the others by itself. Clients then behave
differently depending on which DC happened to answer them — and nothing reports an
error.

The [Samba wiki's](https://wiki.samba.org/index.php/SysVol_replication_(DFS-R))
workaround is to copy SYSVOL with rsync and then reapply the ACLs from AD. This image
ships that as [`adc-sysvol-sync`](overlay/usr/local/sbin/adc-sysvol-sync), run by a
systemd timer:

1. Sync `idmap.ldb` from the source DC once. Without it the same file shows different
   ownership on different DCs, because the SID-to-uid mapping differs.
2. `rsync -aAX --delete` the SYSVOL tree.
3. `samba-tool ntacl sysvolreset`, because rsync carries POSIX bits while the Windows
   ACLs live in AD and have to be reapplied — skip it and clients get access-denied on
   Group Policy.

It needs a root SSH key on the joining DC that is authorised on the source DC. If there
isn't one, the sync **exits with an explanation instead of pretending to work**. That is
deliberate: silent SYSVOL divergence is worse than a visible failure.

This is a real limitation of Samba, not of this image. If you need genuine multi-master
SYSVOL replication, you need Windows DCs.

---

## What Samba does not do

Two gaps matter in practice. Both are Samba's, not this image's.

**No ADWS.** Samba does not implement Active Directory Web Services (TCP 9389), so the
PowerShell `ActiveDirectory` module — `Get-ADUser`, `Get-ADDomain`, `Get-ADDomainController`
— **does not work** against a Samba DC. It fails with "Unable to find a default server
with Active Directory Web Services running."

What does work is everything built on LDAP and RPC, which is most of it:

- **ADUC**, ADSI Edit and the rest of the MMC snap-ins
- Raw LDAP from PowerShell (`DirectoryServices.DirectoryEntry`), `dsquery`, `net`
- `samba-tool` on the DCs themselves

So you manage the domain with the graphical tools or with LDAP, not with the AD
PowerShell cmdlets. Third-party ADWS implementations for Samba exist; none is shipped
here.

**No DFS-R for SYSVOL.** Covered in [The SYSVOL problem](#the-sysvol-problem).

## How it works

```
Debian 13 cloud image (qcow2, official)
   │
   ├─ canonical/packer-maas, "debian" template   (QEMU + KVM)
   │     ├─ cloud-init / netplan / curtin compatibility      [upstream]
   │     └─ customize-samba-ad.sh                            [this repo]
   │           ├─ samba, samba-ad-dc, winbind, krb5, chrony, rsync
   │           ├─ swap the cloud kernel for the generic one
   │           ├─ delete every trace of a domain
   │           ├─ mask smbd/nmbd/winbind, disable networking.service
   │           └─ install the overlay (adc-maas-init, sysvol sync, curtin-hooks)
   │
   └─ samba-ad-dc.tar.gz   ──►   maas boot-resources create
```

On first boot `adc-maas-init` runs these stages, each once, recorded in
`/var/lib/adc-maas/<stage>.done`:

| Stage | What it does |
|---|---|
| `hosts` | Makes the FQDN resolve to the management address. Samba insists on this |
| `identity` | Regenerates anything that must not be shared between clones |
| `time` | Configures chrony, including the signed-NTP socket Windows clients expect |
| `resolver` | Points DNS at the DC being joined, then at itself once it serves DNS |
| `domain` | `samba-tool domain provision` or `samba-tool domain join` |
| `services` | Masks the standalone file-server daemons, starts `samba-ad-dc` |
| `sysvol` | Sets up SYSVOL replication where it is needed |
| `selftest` | Proves Kerberos issues a ticket and SMB answers |

A stage that fails leaves the service failed and is retried on the next boot, rather
than leaving a half-configured domain controller that looks fine.

---

## Requirements

**Build host:** Ubuntu 22.04+ with access to `/dev/kvm`, 4+ vCPU, 8+ GB RAM, 25+ GB
free. If it is a VM, nested virtualization must be on and the CPU type must pass the
flags through (on Proxmox: `--cpu host`).

**Deployment:** MAAS 3.2+ with the curtin preseed from this repository installed on the
region controller.

---

## Quick start

```bash
sudo ./scripts/install-deps.sh     # packer, qemu, ovmf, nbdkit, fuse2fs
sudo make image                    # -> build/samba-ad-dc.tar.gz
make verify
make preseed
sudo make install-preseed          # onto the MAAS region controller
make upload MAAS_PROFILE=admin
```

**The preseed is not optional.** Without it the deployment fails — see
[Traps](#traps-this-image-works-around).

---

## Deploying a domain

### The first DC

```bash
maas $PROFILE machine deploy $SYSTEM_ID \
    osystem=custom distro_series=samba-ad-dc \
    user_data="$(base64 -w0 maas/examples/01-first-dc.yaml)"
```

with, in that user-data:

```
AD_MODE=provision
AD_REALM=AD.EXAMPLE.COM
AD_DOMAIN=EXAMPLE
AD_ADMIN_PASSWORD='...'
AD_DNS_FORWARDER=192.0.2.1
AD_NTP_ALLOW=192.0.2.0/24
```

### Every DC after that

```
AD_MODE=join
AD_REALM=AD.EXAMPLE.COM
AD_DOMAIN=EXAMPLE
AD_JOIN_PEER=192.0.2.10          # an existing DC
AD_ADMIN_PASSWORD='...'          # a Domain Admin on it
AD_SYSVOL_SYNC=on
AD_SYSVOL_SOURCE=192.0.2.10
```

Full examples: [`maas/examples/`](maas/examples/).

### Then

Point the subnet's DHCP at **both** DCs for DNS, and check the domain from either:

```bash
samba-tool domain level show
samba-tool drs showrepl          # replication between DCs
samba-tool fsmo show             # who holds the five roles
```

### Security notes

- `AD_ADMIN_PASSWORD` is plaintext in MAAS user-data, where anyone with MAAS access can
  read it. Use a short-lived password and change it after the domain is up. It is
  scrubbed from `conf.d` on the node once the domain is running
  (`AD_WIPE_SECRETS=true`), but not from MAAS.
- The SYSVOL SSH key, if you supply one through user-data, has the same exposure. Use a
  key dedicated to that job and authorised for nothing else.

---

## Configuration reference

Defaults live in [`/etc/adc-maas/adc-maas.conf`](overlay/etc/adc-maas/adc-maas.conf),
which documents every option. Per-node settings go in `/etc/adc-maas/conf.d/*.conf`,
written by cloud-init from the user-data MAAS supplies, and override the defaults.

| Option | Default | Meaning |
|---|---|---|
| `AD_MODE` | `none` | `none`, `provision` or `join` |
| `AD_REALM` | *(empty)* | Kerberos realm, uppercase DNS domain |
| `AD_DOMAIN` | *(empty)* | NetBIOS name, uppercase, ≤15 chars |
| `AD_ADMIN_PASSWORD` | *(empty)* | Administrator password / join credentials |
| `AD_ADMIN_PASSWORD_FILE` | *(empty)* | Read it from a file instead |
| `AD_JOIN_USER` | `Administrator` | Account used to join |
| `AD_JOIN_PEER` | *(empty)* | An existing DC to join |
| `AD_DNS_BACKEND` | `SAMBA_INTERNAL` | Or `BIND9_DLZ` if you need BIND's features |
| `AD_DNS_FORWARDER` | *(empty)* | Where to send queries the DC is not authoritative for |
| `AD_FUNCTION_LEVEL` | `2008_R2` | Domain and forest functional level |
| `AD_SITE` | `Default-First-Site-Name` | AD site to join |
| `AD_USE_RFC2307` | `true` | Store POSIX uid/gid in AD |
| `AD_INTERFACE` | *(auto)* | Interface Samba binds to |
| `AD_NTP_ALLOW` | *(empty)* | Subnet allowed to use this DC as a time source |
| `AD_SYSVOL_SYNC` | `auto` | `auto` (on for joined DCs), `on`, `off` |
| `AD_SYSVOL_SOURCE` | *(join peer)* | DC to pull SYSVOL from |
| `AD_SYSVOL_INTERVAL` | `5min` | How often |
| `AD_WAIT` / `AD_RETRIES` | `900` / `5` | Waiting for the peer, and join attempts |
| `AD_WIPE_SECRETS` | `true` | Scrub the password from `conf.d` afterwards |
| `AD_ENABLED` | `true` | Set false to disable all first-boot automation |

---

## Operating the domain

```bash
# Users and groups
samba-tool user create alice
samba-tool group addmembers "Domain Admins" alice

# Health
samba-tool drs showrepl                  # is replication working?
samba-tool dns query localhost <realm> @ ALL -U Administrator

# Which DC holds the FSMO roles
samba-tool fsmo show

# The first DC is gone for good: take the roles onto this one
samba-tool fsmo seize --role=all

# A DC that will never come back has to be removed from the directory,
# or replication keeps trying to reach it
samba-tool domain demote --remove-other-dead-server=<name>
```

Windows clients join the domain exactly as they would against a Windows DC, provided
their DNS points at a DC.

---

## Build configuration

| Variable | Default | Meaning |
|---|---|---|
| `DEBIAN_SERIES` / `DEBIAN_VERSION` | `trixie` / `13` | Debian release |
| `AD_EXTRA_PACKAGES` | `acl attr ldap-utils …` | Extra packages baked in |
| `IMAGE_NAME` | `samba-ad-dc` | MAAS name and preseed filename |
| `ARCH` / `BOOT` | `amd64` / `uefi` | Architecture and boot mode |
| `DISK_SIZE` | `16G` | Build VM disk; upstream's 4G is too small |
| `PM_REF` | pinned SHA | `canonical/packer-maas` revision |
| `APT_PROXY` | *(empty)* | Local APT cache, e.g. `http://10.0.2.2:3142` — see `make deps-cache` |

`make check-upstream` compares the `samba` version in Debian against the image you have,
without building anything.

### Build performance

A full build takes about **4m40s** on a 4 vCPU / 4 GB build VM. Where that time goes was
measured rather than guessed, and the result is not what it looked like.

The obvious suspect was slow repository access: inside the build VM apt reported
600-900 kB/s, while the build host itself pulled from `deb.debian.org` at 48 MB/s. But
the pattern gave it away — every fetch over roughly 15 MB took *exactly* 31 seconds no
matter how big it was, while a 14.1 MB fetch took 1 second at 23 MB/s. That is a
connection timeout, not a bandwidth limit. QEMU's user-mode network offers IPv6 that does
not actually work, so apt's parallel connections black-holed on it and only fell back to
IPv4 after 30 seconds.

The Makefile now patches the build VM's cloud-init seed to write
`Acquire::ForceIPv4 "true"` from `bootcmd`, which runs before SSH is up and therefore
covers upstream's own apt calls as well as ours. The same 28.5 MB fetch, across three
builds:

| Build | Setup | Time | Rate |
|---|---|---|---|
| 1 | no cache, no patch | 31 s | 914 kB/s |
| 2 | apt-cacher-ng, no patch | 31 s | 916 kB/s |
| 3 | apt-cacher-ng + `ForceIPv4` | **3 s** | **9152 kB/s** |

That fetch goes over `https`, which a cache passes through a `CONNECT` tunnel without
storing, so build 2 isolates the cache from the patch: the cache changed nothing, the
one-line apt setting was worth 28 seconds.

A local APT cache is still supported and does help on repeat builds, just far less than
you would expect:

```bash
sudo make deps-cache                              # installs apt-cacher-ng
sudo make image APT_PROXY=http://10.0.2.2:3142
```

With a fully warm cache the 26.2 MB Samba fetch went from 2s to 0s (59 MB/s) and the
17.9 MB fetch from 1s to 0s — **about three seconds off a 4m40s build**. The rest of the
time is qemu, dpkg and image compression, none of which a faster mirror touches. A full
Debian trixie amd64 mirror costs about 138 GB; the cache that produced these numbers is
44 MB. Mirror the archive if you want it for other reasons, but not to speed these builds
up.

`10.0.2.2` is the build host as seen from Packer's user-mode network. When a proxy is
configured, repositories are rewritten from `https` to `http` so the cache can serve
them; package signatures are still verified. Debian 13 keeps the real mirror URLs in
`/etc/apt/mirrors/*.list` behind the `mirror+file:` method, so rewriting `sources.list`
alone is not enough.

---

## Traps this image works around

These are the same class of problem as in the sibling
[maas-proxmox](https://github.com/ilkermanap/maas-proxmox) project, and each fails
**silently**:

1. **`kernel: null` in the preseed.** Some curtin versions shipped with MAAS crash on
   it. The image carries `/curtin/curtin-hooks` instead, which disables the kernel
   install and works regardless of curtin version.
2. **Interface renaming.** MAAS records the interface name it saw in its Ubuntu
   commissioning environment; Debian's udev may name the same card differently, and
   cloud-init then fails to rename it and leaves the link **down**. `curtin-hooks`
   pins MAC-to-name mappings so udev gets it right from the start.
3. **systemd ordering.** Ordering the first-boot unit after `cloud-final.service` while
   it is `WantedBy=multi-user.target` forms a cycle, and systemd resolves it by deleting
   the unit's start job — it never runs and reports nothing. The unit is `Type=simple`
   with no cloud-init ordering; the script waits for cloud-init itself.
4. **`networking.service`.** ifupdown starting with the build VM's stale interface
   definition takes the real interface down before any automation runs. It ships
   disabled, and MAAS owns the network.

One was found by testing rather than reading:

5. **A sync service that killed itself.** `adc-sysvol-sync.service` originally declared
   `Requires=samba-ad-dc.service`. The sync restarts `samba-ad-dc` after copying
   `idmap.ldb`, and systemd stops units that *require* a service being restarted — so the
   sync died mid-run with SIGTERM. The timer restarted it and it succeeded, so the
   outcome looked fine while the mechanism was broken. It is `Wants=` now, and the
   restart is `--no-block`.

Two more are specific to this image:

6. **The cloud kernel.** The Debian cloud image ships `linux-image-cloud-amd64`, built
   for virtual machines and missing most physical-hardware drivers. A bare-metal DC
   deployed with it can come up with no disk or no network. The build swaps in the
   generic kernel.
7. **A domain baked into the image.** Installing the packages leaves a default
   `smb.conf`. If that shipped, every machine from the image would start from the same
   half-configured directory and `samba-tool domain provision` would refuse to run. The
   build deletes all of it.

---

## Verified status

Tested end to end on real infrastructure. Be sceptical of anything not listed under
**Verified**.

### Test environment

| | |
|---|---|
| MAAS | 3.7.2 (snap), isolated subnet, MAAS as gateway and DHCP |
| DCs | 2 x (2 vCPU, 6 GB, 32 GiB, UEFI), deployed from this image |
| Windows client | Windows Server 2025 Standard Evaluation, unattended install |
| Realm | `AD.MAASTEST.LAN` / NetBIOS `MAASTEST`, functional level 2008 R2 |
| Image | samba 4.22.10, Debian 13, kernel 6.12.107 |

### Verified

| Area | Evidence |
|---|---|
| Build | 28/28 checks in `make verify`; 412 MB image |
| Build speed | Four builds measured; `ForceIPv4` took the 28.5 MB fetch from 31 s to 3 s, a warm APT cache saved a further ~3 s of 4m40s |
| Release pipeline | Published to a release, downloaded anonymously, SHA-256 matched, uploaded to MAAS |
| Deployment | Both DCs reach `Deployed` from `custom/samba-ad-dc` |
| **Provisioning** | First DC created the domain in 21 s, unattended, first attempt |
| **Joining** | Second DC joined in 23 s, first attempt |
| Kerberos | The built-in self-test obtained a ticket for `Administrator@AD.MAASTEST.LAN` on both DCs |
| Replication | `samba-tool drs showrepl`: outbound neighbours, last attempt successful, 0 consecutive failures |
| FSMO | All five roles on the first DC, as expected |
| **SYSVOL replication** | A file written on DC1 appeared on DC2 within one timer interval; log shows the `idmap.ldb` sync, the rsync and `ntacl sysvolreset` |
| Credential scrubbing | `AD_ADMIN_PASSWORD` removed from `conf.d` after provisioning on both DCs |
| SMB shares | `sysvol` and `netlogon` served; contents readable with domain credentials |
| **Windows DC discovery** | `_ldap._tcp.dc._msdcs.ad.maastest.lan` resolved to `maas-node8:389` |
| **Windows domain join** | `Add-Computer` succeeded; after reboot `PartOfDomain=True`, `Test-ComputerSecureChannel=True` |
| DC capability flags | `nltest /dsgetdc` reports `PDC GC DS LDAP KDC TIMESERV GTIMESERV WRITABLE DNS_DC DNS_DOMAIN DNS_FOREST FULL_SECRET` |
| **Group Policy** | `gpupdate /force /target:computer` completed successfully; `gpresult` shows the domain and site |
| SYSVOL from Windows | Readable over UNC with domain credentials, including the replicated test file |
| LDAP from Windows | `DirectoryServices.DirectoryEntry` listed both DCs and the Windows machine account, and the domain users |

### Not verified

- **Windows client OS** (10/11) joining — only Windows Server 2025 was tested
- Applying an actual **Group Policy object** and observing its effect; only the GPO refresh mechanism was exercised
- **Interactive** domain logon at the Windows console, and ADUC's GUI. LDAP was proven with explicit credentials, which is the path ADUC uses, but the MMC snap-in itself was not opened
- Losing a DC and **seizing FSMO roles**
- More than two DCs, and concurrent joins
- `BIND9_DLZ` — only `SAMBA_INTERNAL` DNS was used
- `AD_SYSVOL_SYNC` without an SSH key, i.e. the refuse-and-explain path
- Real **bare metal** — both DCs were virtual machines
- **arm64**
- Domain **trusts**, and interop with a Windows DC in the same forest

### Known not to work

- **ADWS**: port 9389 is closed, confirmed from the Windows client. The PowerShell
  `ActiveDirectory` module cannot be used. See
  [What Samba does not do](#what-samba-does-not-do).

## Licensing

**AGPL-3.0-or-later**, see [LICENSE](LICENSE).

The build pipeline derives from [`canonical/packer-maas`](https://github.com/canonical/packer-maas)
(AGPLv3) — the curtin preseed and `curtin-hooks` in particular — so the copyleft carries
over. The upstream template is cloned at build time, not vendored.

Samba itself is GPLv3+ and is installed from Debian, unmodified.
