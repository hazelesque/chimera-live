#!/bin/sh
#
# mkrescue-disk.sh — wrap a UKI (or any EFI binary) as a bootable
# qcow2 disk.
#
# Output: a single qcow2 with a GPT + an ESP-typed FAT32 partition
# containing the supplied .efi at /EFI/BOOT/BOOTX64.EFI (UEFI
# default-boot path).  OVMF auto-boots it as soon as it's the only
# bootable disk, or it's selectable from the firmware boot manager
# (Esc/F2 at startup) when attached alongside other disks.
#
# Use case: rescue / diagnostic disk attached to a wedged guest
# whose primary disk won't boot.  Boot the rescue, mount the guest's
# disks read-only, inspect, repair.
#
# Usage: doas ./mkrescue-disk.sh [-o OUT] [-s SIZE] EFI_FILE
#
# License: BSD-2-Clause

. ./lib.sh

OUT_FILE=
IMAGE_SIZE=512M

usage() {
    cat <<EOF
Usage: $PROGNAME [opts] EFI_FILE

Builds a bootable qcow2 disk containing only EFI_FILE at
/EFI/BOOT/BOOTX64.EFI on a GPT-typed ESP partition.

Options:
  -o FILE    Output qcow2 (default: <efi-basename-without-suffix>-disk.qcow2)
  -s SIZE    Image size (default: ${IMAGE_SIZE})
  -h         Print this message.
EOF
    exit "${1:-1}"
}

while getopts "o:s:h" opt; do
    case "$opt" in
        o) OUT_FILE="$OPTARG";;
        s) IMAGE_SIZE="$OPTARG";;
        h) usage 0;;
        *) usage;;
    esac
done
shift $((OPTIND - 1))

EFI_FILE="$1"
[ -n "$EFI_FILE" ] || die "missing EFI binary positional argument"
[ -r "$EFI_FILE" ] || die "cannot read $EFI_FILE"

# ---- pre-flight ---------------------------------------------------

for tool in losetup truncate sfdisk mkfs.vfat qemu-img mcopy mmd; do
    command -v "$tool" > /dev/null 2>&1 || die "missing required tool: $tool"
done

# Derive default output filename from the .efi basename.
if [ -z "$OUT_FILE" ]; then
    base=$(basename -- "$EFI_FILE")
    base="${base%.efi}"
    OUT_FILE="${base}-disk.qcow2"
fi
OUT_FILE=$(realpath -m "$OUT_FILE")
RAW="${OUT_FILE%.qcow2}.raw"
EFI_FILE=$(realpath "$EFI_FILE") || die "realpath $EFI_FILE failed"

# ---- cleanup -----------------------------------------------------

LOOP=
cleanup() {
    rc=$?
    set +e
    sync
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" > /dev/null 2>&1
        LOOP=
    fi
    exit "$rc"
}
trap cleanup INT TERM EXIT

# ---- step 1: create raw image + loop-attach -----------------------

msg "Creating ${IMAGE_SIZE} raw image at $RAW..."
truncate -s "$IMAGE_SIZE" "$RAW" || die "truncate failed"
LOOP=$(losetup --show -fP "$RAW") || die "losetup failed"
msg "Loop device: $LOOP"

# ---- step 2: partition (single ESP spanning the disk) ------------
#
# Reuse mkcloud.sh's RFC-4122-valid sentinel UUID convention so an
# operator looking at /dev/disk/by-partuuid/c1ec1c1e-... knows
# this disk came from our tooling.  c1ec1c1e-...-000000000099 is
# the rescue-disk single-ESP marker (distinct from mkcloud's
# ...000000000001/2 used for cloud-VM ESP/root).

msg "Partitioning GPT (single ESP)..."
sfdisk --wipe always --wipe-partitions always "$LOOP" <<EOF || die "sfdisk failed"
label: gpt
first-lba: 2048
unit: sectors

name=esp, type=U, uuid=c1ec1c1e-0000-4000-8000-000000000099
EOF

sync
partprobe "$LOOP" > /dev/null 2>&1 || true
udevadm settle 2>/dev/null || sleep 1

# ---- step 3: format ESP -------------------------------------------

msg "Formatting ESP (vfat32) at ${LOOP}p1..."
mkfs.vfat -F32 -n RESCUE_ESP -i cafebabe "${LOOP}p1" > /dev/null \
    || die "mkfs.vfat failed"

# ---- step 4: populate ESP via mtools (no mount needed) -----------
#
# mmd + mcopy operate directly on the FAT image — no mount, no
# pseudo-fs juggling, no `mount_pseudo` shenanigans, no possibility
# of writing to the host's /dev by accident.  Same trick mklive.sh
# uses for its el-torito ESP image.

msg "Copying $EFI_FILE -> /EFI/BOOT/BOOTX64.EFI on ESP..."
LC_CTYPE=C mmd -i "${LOOP}p1" ::/EFI         || die "mmd EFI failed"
LC_CTYPE=C mmd -i "${LOOP}p1" ::/EFI/BOOT    || die "mmd EFI/BOOT failed"
LC_CTYPE=C mcopy -i "${LOOP}p1" "$EFI_FILE" ::/EFI/BOOT/BOOTX64.EFI \
    || die "mcopy failed"

# ---- step 5: detach loop ------------------------------------------

msg "Detaching loop..."
losetup -d "$LOOP" || die "losetup -d failed"
LOOP=

# ---- step 6: qcow2 convert ----------------------------------------
#
# Sparse, no compression — same default as mkcloud.sh; rescue disks
# are typically loaded fresh each time.

msg "Converting to qcow2 at $OUT_FILE..."
qemu-img convert -f raw -O qcow2 -p "$RAW" "$OUT_FILE" \
    || die "qemu-img convert failed"
rm -f "$RAW"

OUT_SIZE=$(du -h "$OUT_FILE" | awk '{print $1}')
msg "Done: $OUT_FILE ($OUT_SIZE)"
msg ""
msg "Attach via libvirt domain XML:"
msg ""
msg "  <disk type='file' device='disk'>"
msg "    <driver name='qemu' type='qcow2'/>"
msg "    <source file='$OUT_FILE'/>"
msg "    <target dev='vdX' bus='virtio'/>"
msg "    <readonly/>"
msg "  </disk>"
msg ""
msg "OVMF auto-boots /EFI/BOOT/BOOTX64.EFI when this is the only"
msg "bootable disk; otherwise select from firmware boot menu (Esc/F2)."
