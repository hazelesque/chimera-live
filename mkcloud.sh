#!/bin/sh
#
# mkcloud.sh — Chimera Linux cloud-VM image builder.
#
# Takes a rootfs tarball produced by mkrootfs-cloud.sh and turns it
# into a bootable .qcow2 for libvirt/qemu under OVMF.  Pure UEFI;
# no BIOS hybrid; no ISO.  Two variants selected via -c:
#
#   serial (default) — console=hvc0 (virtio-console).  Limine sets
#                      timeout=0 and serial:yes; Chimera's
#                      nyagetty-dinit auto-detects hvc0 from
#                      /proc/cmdline and spawns a getty.  This is
#                      the variant Tilley exercises.
#   video             — console=tty0 (graphical).  Limine sets
#                      timeout=1; we write /etc/default/agetty so
#                      EXTRA_GETTYS=/dev/tty1 opts the graphical tty
#                      back in (the auto-detect filter skips
#                      tty[0-9]*).
#
# Same rootfs tarball serves both variants; package set is identical,
# only runtime config differs.  Output filename carries the variant
# suffix.
#
# Plan reference: /home/hazel/.claude/plans/also-note-you-will-modular-wigderson.md
#
# Open-item resolutions confirmed during pre-implementation
# verification (so the script's hardcoded paths/names are accurate):
#
#   - cloud-init-dinit ships cloud-init-local, cloud-init,
#     cloud-config, cloud-final under /usr/lib/dinit.d/ with
#     correct depends-on/before declarations between phases —
#     no need to write override service files locally.
#   - Chimera ships early-machine-id (under /usr/lib/dinit.d/early-)
#     which regenerates /etc/machine-id if empty on first boot —
#     no need for a custom machine-id-seed service.  Step 15
#     simplifies to `: > /etc/machine-id`.
#   - nyagetty-dinit ships a smart auto-detect agetty dispatcher
#     that parses console= from /proc/cmdline.  Handles hvc0
#     natively; tty[0-9]* requires EXTRA_GETTYS=/dev/tty1 in
#     /etc/default/agetty (see step 13 video branch).
#   - qemu-guest-agent's service is "qemu-ga" (not
#     "qemu-guest-agent" as initially guessed).
#   - chrony ships both "chronyd" (daemon) and "chrony" (a
#     wait-for-sync wrapper).  We enable chronyd; the wrapper
#     is operationally useful but not needed for cloud-VM time
#     sync.
#   - sshd transitively pulls ssh-keygen via depends-on — no
#     separate enable needed; sshd's symlink is sufficient.
#   - linux-stable kernels ship CONFIG_VIRTIO_CONSOLE (verified
#     against host 7.0.3-0-generic) so the serial variant's
#     hvc0 path Just Works.
#
# Fallback if VIRTIO_CONSOLE is ever missing from linux-stable
# (open item #8): four touchpoints, all in this file or sibling
# templates, must update together:
#   - limine/limine-cloud-serial.conf.in → console=ttyS0,115200
#   - DINIT_SERVICES_SERIAL → add hand-written serial-getty-ttyS0
#     service (write via cat-heredoc here)
#   - qemu verification command in plan §Verification → use
#     -serial mon:stdio instead of virtio-console plumbing
#   - this header comment + symlink list below
#
# License: BSD-2-Clause
#

. ./lib.sh

# ---- defaults -----------------------------------------------------

VARIANT=serial
IMAGE_SIZE=8G
OUT_FILE=
COMPRESS=0
# ESP_EXTRAS is a newline-separated list of "SRC[:DEST]" pairs.
# Populated by repeated `-x` flags.  Each entry gets copied to
# the ESP at /<DEST> (or /<basename SRC> if DEST omitted) during
# step 16a.  Useful for dropping a rescue UKI, shellx64.efi
# overrides, additional bootloader configs, etc. onto the ESP
# alongside the standard limine + kernel + initrd layout.
ESP_EXTRAS=

# Fixed sentinel UUIDs — RFC 4122 format-valid (version=4,
# variant=10xx in nibbles 3 and 4 of groups 3+4).  The c1ec1c1e
# prefix is operator-recognisable as "this disk came from
# mkcloud.sh".  cafebabe is the FAT32 volume-id (32-bit hex).
ESP_PARTUUID_FIXED=c1ec1c1e-0000-4000-8000-000000000001
ROOT_PARTUUID_FIXED=c1ec1c1e-0000-4000-8000-000000000002
ROOT_FSUUID_FIXED=c1ec1c1e-0000-4000-8000-000000000003
ESP_VOLID_FIXED=cafebabe

# Service-name parameterisation per plan open item #1 — adjust if
# any package's dinit service name changes upstream.  All names
# verified against the relevant -dinit subpackages at plan time.
DINIT_SERVICES_COMMON="sshd ifupdown-ng chronyd acpid qemu-ga \
                      cloud-init-local cloud-init cloud-config cloud-final \
                      syslog-ng \
                      agetty"
# Serial variant: agetty auto-detect handles hvc0 via /proc/cmdline.
DINIT_SERVICES_SERIAL=""
# Video variant: agetty auto-detect skips tty[0-9]*; we opt tty1
# back in via /etc/default/agetty's EXTRA_GETTYS.  No additional
# service to enable.
DINIT_SERVICES_VIDEO=""

# ---- arg parsing --------------------------------------------------

usage() {
    cat <<EOF
Usage: $PROGNAME [opts] ROOTFS_TARBALL

Builds a bootable .qcow2 from a cloud-flavoured rootfs tarball.

Options:
  -c VARIANT     serial (default) or video
  -o FILE        Output file name
                 (default: chimera-linux-<arch>-CLOUD-<date>-<variant>.qcow2)
  -s SIZE        Image size (default: ${IMAGE_SIZE})
  -C             Compress the qcow2 with zstd (default: sparse, no compression)
  -x SRC[:DEST]  Drop SRC onto the ESP at /DEST (or /\$(basename SRC)
                 if DEST omitted).  Repeatable.  Useful for staging
                 a rescue UKI, an EFI shell override, or extra
                 bootloader configs alongside the standard layout.
                 Example: -x chimera-rescue-zfs.efi:EFI/rescue/rescue.efi
  -h             Print this message.
EOF
    exit "${1:-1}"
}

while getopts "c:o:s:Cx:h" opt; do
    case "$opt" in
        c) VARIANT="$OPTARG";;
        o) OUT_FILE="$OPTARG";;
        s) IMAGE_SIZE="$OPTARG";;
        C) COMPRESS=1;;
        x) ESP_EXTRAS="${ESP_EXTRAS}${OPTARG}
";;
        h) usage 0;;
        *) usage;;
    esac
done

shift $((OPTIND - 1))

case "$VARIANT" in
    serial|video) ;;
    *) die "unknown variant: $VARIANT (want: serial, video)" ;;
esac

ROOTFS_TARBALL="$1"
[ -n "$ROOTFS_TARBALL" ] || die "missing rootfs tarball argument"
[ -r "$ROOTFS_TARBALL" ] || die "cannot read rootfs tarball: $ROOTFS_TARBALL"

# Validate ESP extras early — fail before any disk operations if
# any source is missing.  Each entry is "SRC[:DEST]"; split on the
# first colon.  Catches the "you meant to drop the rescue UKI but
# typo'd the path" case before mkfs.
if [ -n "$ESP_EXTRAS" ]; then
    printf '%s' "$ESP_EXTRAS" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *:*) src="${line%%:*}" ;;
              *) src="$line" ;;
        esac
        [ -r "$src" ] || die "ESP extra source missing or unreadable: $src"
    done || exit 1
fi

# ---- pre-flight ---------------------------------------------------

for tool in losetup truncate sfdisk mkfs.vfat mkfs.ext4 qemu-img tar; do
    command -v "$tool" > /dev/null 2>&1 || die "missing required tool: $tool"
done

# Derive arch + date for the default output filename.  Match
# mkrootfs.sh's naming convention.
ARCH=$(uname -m)
DATE=$(date '+%Y%m%d')
[ -n "$OUT_FILE" ] || OUT_FILE="chimera-linux-${ARCH}-CLOUD-${DATE}-${VARIANT}.qcow2"

RAW="${OUT_FILE%.qcow2}.raw"

# ---- cleanup -------------------------------------------------------
#
# lib.sh installs its own EXIT trap that calls umount_pseudo.  Our
# trap supersedes it to additionally release the loop device + remove
# the mount-point dir.  Per Hazel's
# feedback_dont_cleanup_artefacts_unprompted.md, we deliberately
# DO NOT remove $RAW or $OUT_FILE on failure — leave them for
# operator inspection.

LOOP=
ROOT_DIR=

cleanup() {
    rc=$?
    set +e
    sync
    # Unmount the boot partition first (it's mounted under the root
    # partition's mountpoint).
    if [ -n "$ROOT_DIR" ]; then
        umount "${ROOT_DIR}/boot" > /dev/null 2>&1
    fi
    # lib.sh's helper unmounts dev/proc/sys + the root mount itself.
    umount_pseudo
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" > /dev/null 2>&1
        LOOP=
    fi
    if [ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
        rmdir "$ROOT_DIR" > /dev/null 2>&1
    fi
    exit "$rc"
}
trap cleanup INT TERM EXIT

# ---- step 3+4: create raw image + loop attach ---------------------

msg "Creating ${IMAGE_SIZE} raw image at $RAW..."
truncate -s "$IMAGE_SIZE" "$RAW" || die "truncate failed"
LOOP=$(losetup --show -fP "$RAW") || die "losetup failed"
msg "Loop device: $LOOP"

# ---- step 5: partition --------------------------------------------

msg "Partitioning GPT..."
sfdisk --wipe always --wipe-partitions always "$LOOP" <<EOF || die "sfdisk failed"
label: gpt
first-lba: 2048
unit: sectors

name=esp,  size=1G, type=U, uuid=${ESP_PARTUUID_FIXED}
name=root,          type=L, uuid=${ROOT_PARTUUID_FIXED}
EOF

# Make sure the kernel sees the new partitions before we mkfs.
sync
partprobe "$LOOP" > /dev/null 2>&1 || true
# Give udev a moment to settle (the partition device nodes may not
# exist immediately after partprobe on some kernels).
udevadm settle 2>/dev/null || sleep 1

# ---- step 6: format with fixed FS UUIDs ---------------------------

msg "Formatting ESP (vfat) at ${LOOP}p1 + root (ext4) at ${LOOP}p2..."
mkfs.vfat -F32 -n CHIMERA_ESP -i "${ESP_VOLID_FIXED}" "${LOOP}p1" > /dev/null \
    || die "mkfs.vfat failed"
mkfs.ext4 -q -L chimera_root -U "${ROOT_FSUUID_FIXED}" -F "${LOOP}p2" \
    || die "mkfs.ext4 failed"

# ---- step 7: capture PARTUUIDs ------------------------------------

# Cross-check against the fixed UUIDs from step 5 — surfacing any
# disagreement here would mean the sfdisk script and our captured
# values disagree, which is a script bug worth knowing about.
# Lowercase the captured values: sfdisk accepts lowercase on
# write but emits uppercase on read (`--part-uuid <dev> <n>` =>
# uppercase hex).  Lowercase everywhere for consistency with the
# sentinel constants + udev's lowercase /dev/disk/by-partuuid/
# symlinks + lower-case PARTUUID= in /etc/fstab.
ROOT_PARTUUID=$(sfdisk --part-uuid "$LOOP" 2 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
ESP_PARTUUID=$(sfdisk --part-uuid "$LOOP" 1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[ "$ROOT_PARTUUID" = "$ROOT_PARTUUID_FIXED" ] \
    || die "root PARTUUID mismatch: got '$ROOT_PARTUUID', expected '$ROOT_PARTUUID_FIXED'"
[ "$ESP_PARTUUID" = "$ESP_PARTUUID_FIXED" ] \
    || die "ESP PARTUUID mismatch: got '$ESP_PARTUUID', expected '$ESP_PARTUUID_FIXED'"

# ---- step 8: mount root, then ESP under it ------------------------

ROOT_DIR=$(mktemp -d /tmp/mkcloud-mnt-XXXXXX) || die "mktemp failed"
msg "Mounting root + ESP at $ROOT_DIR..."
mount "${LOOP}p2" "$ROOT_DIR" || die "root mount failed"
mkdir -p "${ROOT_DIR}/boot"
mount "${LOOP}p1" "${ROOT_DIR}/boot" || die "esp mount failed"

# ---- step 9: extract rootfs ---------------------------------------

msg "Extracting rootfs tarball..."
tar -C "$ROOT_DIR" -xpf "$ROOTFS_TARBALL" || die "tar extract failed"

# ---- step 10: pseudo-fs mounts ------------------------------------

mount_pseudo

# ---- step 11: detect kernel + generate initramfs ------------------

KERNVER=$(ls "${ROOT_DIR}/usr/lib/modules" 2>/dev/null | sort -V | tail -1)
[ -n "$KERNVER" ] || die "no kernel modules found under ${ROOT_DIR}/usr/lib/modules"
# The modules-dir name already contains the flavor suffix (e.g.
# "7.0.9-0-generic" = "<ver>-<rel>-<flavor>"); kernel image, modules
# dir, and initramfs filename all share that exact string.  Don't
# append "-generic" again — that's a Debian-ism, not Chimera's
# layout.
msg "Generating initramfs for ${KERNVER}..."
chroot "$ROOT_DIR" mkinitramfs -o "/boot/initrd.img-${KERNVER}" "$KERNVER" \
    || die "mkinitramfs failed for ${KERNVER}"

# Sanity-check kernel image landed where limine.conf expects it.
[ -r "${ROOT_DIR}/boot/vmlinuz-${KERNVER}" ] \
    || die "kernel image missing at /boot/vmlinuz-${KERNVER}"

# ---- step 12: /etc/fstab ------------------------------------------

msg "Writing /etc/fstab..."
cat > "${ROOT_DIR}/etc/fstab" <<EOF
# Generated by mkcloud.sh — fixed sentinel PARTUUIDs.
PARTUUID=${ROOT_PARTUUID}  /     ext4  defaults              0  1
PARTUUID=${ESP_PARTUUID}   /boot vfat  defaults,umask=0077   0  2
EOF

# ---- step 13: enable dinit services -------------------------------

msg "Enabling dinit services..."
BOOTD="${ROOT_DIR}/etc/dinit.d/boot.d"
mkdir -p "$BOOTD"
# Symlinks use absolute /lib/dinit.d/<svc> paths matching the host
# convention (Hazel's host's boot.d uses /lib/dinit.d/...).
# /lib is a symlink to /usr/lib on Chimera; the package files
# actually live under /usr/lib/dinit.d/, but the /lib path resolves
# correctly via the symlink.
for svc in $DINIT_SERVICES_COMMON; do
    if [ ! -e "${ROOT_DIR}/usr/lib/dinit.d/$svc" ]; then
        die "missing dinit service file: /usr/lib/dinit.d/$svc (package install incomplete?)"
    fi
    ln -sf "/lib/dinit.d/$svc" "$BOOTD/$svc"
done

# Variant-specific enables (empty for both today; here so the
# template is easy to extend).
case "$VARIANT" in
    serial)
        for svc in $DINIT_SERVICES_SERIAL; do
            ln -sf "/lib/dinit.d/$svc" "$BOOTD/$svc"
        done
        ;;
    video)
        for svc in $DINIT_SERVICES_VIDEO; do
            ln -sf "/lib/dinit.d/$svc" "$BOOTD/$svc"
        done
        # Opt graphical tty1 into the agetty dispatcher's
        # EXTRA_GETTYS list — Chimera's auto-detect skips
        # tty[0-9]* by default ("managed differently") so we
        # explicitly re-enable it.  See /usr/lib/dinit-agetty
        # for the filter logic.
        mkdir -p "${ROOT_DIR}/etc/default"
        cat > "${ROOT_DIR}/etc/default/agetty" <<'EOF'
# Written by mkcloud.sh (video variant).  Opts /dev/tty1 into
# nyagetty-dinit's auto-detect.  Without this, video-variant VMs
# would have no getty on the graphical console.
EXTRA_GETTYS="/dev/tty1"
EOF
        ;;
esac

# ---- step 13b: /etc/network/interfaces (ifupdown-ng baseline) ----
#
# ifupdown-ng's dinit service runs `ifquery --list -a` to enumerate
# `auto`-flagged interfaces from /etc/network/interfaces.  Without
# this file (or with no auto interfaces), the service exits cleanly
# without bringing anything up.  Bake a baseline: loopback + DHCP
# on eth0.
#
# eth0 (not enp1s0) is the right name because the limine templates
# pass `net.ifnames=0` on the kernel cmdline, disabling predictable
# interface naming.  Cleaner than chasing whatever predictable name
# udev would compute for the virtio NIC.
#
# cloud-init may overwrite this on first boot if its network-config
# renderer is configured for ifupdown-ng — that's fine; the baked
# file just covers the dinit-startup-before-cloud-init window.

msg "Writing baseline /etc/network/interfaces..."
mkdir -p "${ROOT_DIR}/etc/network"
cat > "${ROOT_DIR}/etc/network/interfaces" <<'EOF'
# Baseline written by mkcloud.sh.  ifupdown-ng's dinit wrapper
# enumerates auto-flagged interfaces from here.  cloud-init may
# overwrite on first boot.
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# ---- step 14: cloud-init datasource preference --------------------

msg "Baking NoCloud datasource preference..."
mkdir -p "${ROOT_DIR}/etc/cloud/cloud.cfg.d"
cat > "${ROOT_DIR}/etc/cloud/cloud.cfg.d/99_datasource_list.cfg" <<EOF
# Written by mkcloud.sh — skip EC2/Azure/GCE probing on first boot,
# go straight to NoCloud (config-drive / SMBIOS / cidata.iso).
# Tilley's contract is NoCloud-shaped.
datasource_list: [ NoCloud, None ]
EOF

# ---- step 15: machine-id hygiene ----------------------------------
#
# Chimera's early-machine-id (in /usr/lib/dinit.d/early-) regenerates
# /etc/machine-id when it's empty or missing.  Just empty it; the
# early script handles the rest.  Same for the legacy dbus path.

: > "${ROOT_DIR}/etc/machine-id"
if [ -e "${ROOT_DIR}/var/lib/dbus/machine-id" ]; then
    : > "${ROOT_DIR}/var/lib/dbus/machine-id"
fi

# ---- step 16: populate ESP — limine binary ------------------------

msg "Installing limine to /boot/EFI/BOOT/BOOTX64.EFI..."
mkdir -p "${ROOT_DIR}/boot/EFI/BOOT"
[ -r "${ROOT_DIR}/usr/share/limine/BOOTX64.EFI" ] \
    || die "limine package missing BOOTX64.EFI at /usr/share/limine/"
cp "${ROOT_DIR}/usr/share/limine/BOOTX64.EFI" \
   "${ROOT_DIR}/boot/EFI/BOOT/BOOTX64.EFI"

# ---- step 17: write limine.conf from variant template -------------
#
# Per Limine v12.x CONFIG.md the search order is:
#   1. <EFI app path>/limine.conf  (= /EFI/BOOT/limine.conf for us)
#   2. /boot/limine/limine.conf
#   3. /boot/limine.conf
#   4. /limine/limine.conf
#   5. /limine.conf  (ESP root)
#
# Path #1 SHOULD work but qemu+OVMF testing showed Limine 12.2.0
# reporting "config file not found" with the config at
# /EFI/BOOT/limine.conf — likely an OVMF→Limine boot-path handoff
# quirk where Limine can't reliably extract its own dir.
#
# Write to /limine.conf (ESP root, path #5) instead.  It's
# hardcoded, doesn't depend on UEFI boot-path-extraction working,
# and is the most robust hit in the search loop.  Cost: same
# 260 bytes, just at a different cluster.

msg "Writing limine.conf (variant: $VARIANT)..."
case "$VARIANT" in
    serial) TEMPLATE=limine/limine-cloud-serial.conf.in ;;
    video)  TEMPLATE=limine/limine-cloud-video.conf.in ;;
esac
[ -r "$TEMPLATE" ] || die "missing limine template: $TEMPLATE"
sed -e "s|@@KERNVER@@|${KERNVER}|g" \
    -e "s|@@ROOT_PARTUUID@@|${ROOT_PARTUUID}|g" \
    "$TEMPLATE" > "${ROOT_DIR}/boot/limine.conf"

# ---- step 17a: optional EFI shell --------------------------------
#
# If the operator has a shellx64.efi sitting next to this script,
# drop it at /shellx64.efi on the ESP.  OVMF's firmware boot menu
# auto-discovers EFI binaries at that path and offers them as a
# boot option ("EFI Internal Shell" or similar) without any NVRAM
# entry config.  Useful for poking around the boot environment
# when limine misbehaves.  Skip silently if the file isn't there.

if [ -r ./shellx64.efi ]; then
    msg "Installing EFI shell to /shellx64.efi on ESP..."
    cp ./shellx64.efi "${ROOT_DIR}/boot/shellx64.efi"
fi

# ---- step 17b: operator-supplied ESP extras ----------------------
#
# Each `-x SRC[:DEST]` from the args lands at
# ${ROOT_DIR}/boot/<DEST> (or basename SRC if DEST omitted).
# Sources already validated in pre-flight; we still check
# readability defensively in case something disappeared between
# validation and now.  Subdirs in DEST are created automatically.

if [ -n "$ESP_EXTRAS" ]; then
    msg "Copying operator-supplied ESP extras..."
    printf '%s' "$ESP_EXTRAS" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *:*) src="${line%%:*}"; dest="${line#*:}" ;;
              *) src="$line"; dest=$(basename -- "$line") ;;
        esac
        [ -r "$src" ] || die "ESP extra source vanished: $src"
        # Strip any leading '/' from dest — we're already rooted
        # at the ESP via ${ROOT_DIR}/boot/.
        dest="${dest#/}"
        dest_full="${ROOT_DIR}/boot/${dest}"
        dest_dir=$(dirname -- "$dest_full")
        mkdir -p "$dest_dir" || die "mkdir -p $dest_dir failed"
        cp "$src" "$dest_full" || die "cp $src -> $dest_full failed"
        msg "  $src -> /${dest}"
    done || exit 1
fi

# ---- step 18+19+20: unmount + detach ------------------------------

msg "Unmounting + detaching loop..."
umount_pseudo
umount "${ROOT_DIR}/boot" || die "esp umount failed"
umount "$ROOT_DIR" || die "root umount failed"
rmdir "$ROOT_DIR" || true
ROOT_DIR=
losetup -d "$LOOP" || die "losetup -d failed"
LOOP=

# ---- step 21: qcow2 convert ---------------------------------------

if [ "$COMPRESS" = "1" ]; then
    msg "Converting to compressed qcow2 (zstd) at $OUT_FILE..."
    qemu-img convert -f raw -O qcow2 \
        -o compression_type=zstd -c -p \
        "$RAW" "$OUT_FILE" || die "qemu-img convert failed"
else
    msg "Converting to sparse qcow2 at $OUT_FILE..."
    qemu-img convert -f raw -O qcow2 -p "$RAW" "$OUT_FILE" \
        || die "qemu-img convert failed"
fi

# ---- step 22: remove raw scratch ----------------------------------

rm -f "$RAW"

msg "Done: $OUT_FILE (variant=$VARIANT, kernel=$KERNVER)"
msg "  Boot under OVMF; serial variant exposes hvc0 via virtio-console,"
msg "  video variant exposes tty1 via the graphical console."
