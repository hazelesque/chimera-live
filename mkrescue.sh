#!/bin/sh
#
# mkrescue.sh — Chimera Linux rescue UKI builder.
#
# Output: a single Unified Kernel Image (.efi) containing a Linux
# kernel + a self-contained rootfs-as-initramfs.  Drop on any ESP
# at /EFI/<whatever>/rescue.efi and select from the firmware boot
# manager — boots into a tmpfs-only rescue environment with
# auto-login on tty1, ttyS0, and hvc0.
#
# Use case: cloud-VM debugging.  When mkcloud.sh's regular image
# won't boot, won't SSH in, or has a wedged cloud-init, the
# rescue UKI gives the operator a root shell + diagnostic tools +
# `apk add` + `chimera-installer` for nuke-and-pave install.
#
# This is NOT a true USI (Unified System Image — UKI + verity-
# signed rootfs in additional PE sections).  It's a UKI where the
# initramfs IS the whole system; no pivot-to-disk, no separate
# rootfs partition.  Single .efi file is the operational ask.
#
# Variants:
#   zfs (default) — includes zfs userspace + linux-stable-zfs-bin
#                   so `zpool import` works against a busted pool.
#   minimal (future) — TODO; same shape, smaller package set.
#
# Usage: doas ./mkrescue.sh [-v VARIANT] [-p "extra pkgs"]
#
# License: BSD-2-Clause

. ./lib.sh

VARIANT=zfs
EXTRA_PKGS=

usage() {
    cat <<EOF
Usage: $PROGNAME [-v VARIANT] [-p "extra packages"]

Builds a Chimera Linux rescue UKI.

Options:
  -v VARIANT  zfs (default).  Future: minimal.
  -p PKGS     Additional apk packages to install.
  -h          Print this message.
EOF
    exit "${1:-1}"
}

while getopts "v:p:h" opt; do
    case "$opt" in
        v) VARIANT="$OPTARG";;
        p) EXTRA_PKGS="$OPTARG";;
        h) usage 0;;
        *) usage;;
    esac
done

shift $((OPTIND - 1))

case "$VARIANT" in
    zfs) ;;
    *) die "unknown variant: $VARIANT (want: zfs)" ;;
esac

# ---- tool pre-flight ----------------------------------------------

for tool in cpio zstd ukify apk realpath; do
    command -v "$tool" > /dev/null 2>&1 || die "missing required tool: $tool"
done

# ---- package set --------------------------------------------------
#
# base-bootstrap is the tiniest Chimera base.  We layer everything
# we actually want for a rescue image explicitly.  base-full would
# work too but pulls in pipewire, polkit, elogind, firmware blobs,
# locales, and other things we don't want in a UKI that has to fit
# in a few hundred MB of cpio.
#
# Diagnostic tools chosen for the "what's wrong with this VM"
# scenario: filesystem inspection, network poking, hardware
# enumeration, log/log-extraction, scripting languages.

BASE_PKGS="\
base-bootstrap \
dinit dinit-chimera dinit-chimera-udev nyagetty-dinit nyagetty-dinit-links \
chimerautils \
\
linux-stable \
\
apk-tools ca-certificates \
chimera-install-scripts \
\
util-linux e2fsprogs xfsprogs dosfstools \
lvm2 mdadm parted gptfdisk \
ddrescue \
\
chrony-dinit \
dhcpcd dhcpcd-dinit \
openssh openssh-dinit \
iproute2 iputils \
\
vim less file findutils gawk \
strace lsof htop tcpdump \
\
pciutils usbutils dmidecode \
"
# grep + sed come from chimerautils (BSD reimplementations) so
# don't list them separately.  openssh ships both sshd + ssh-client
# in a single package (no separate -client subpackage).  gdisk's
# Chimera name is gptfdisk; ncurses-tools doesn't exist as a name
# (the tools are in the main ncurses package, which sd-tools pulls
# in transitively).  dinit-links isn't a real package — service
# enablement is either via per-package <foo>-dinit-links subpkgs
# (which we skip for the rescue image; explicit symlinks below)
# or via the symlink writes in steps 4 + 6.

case "$VARIANT" in
    zfs)
        PKGS="$BASE_PKGS zfs zfs-dinit zfs-udev linux-stable-zfs-bin"
        ;;
esac

# ---- output naming ------------------------------------------------

ARCH=$(uname -m)
DATE=$(date '+%Y%m%d')
OUT="chimera-rescue-${VARIANT}-${DATE}-${ARCH}.efi"
# realpath -m for "make canonical, don't require existence" —
# without -m, realpath silently emits the empty string on
# missing paths and the script proceeds with empty variables.
RDIR=$(realpath -m "./rescue-build-${VARIANT}")
# INITRD path must be ABSOLUTE because step 8's cpio pipeline
# runs in a `cd "$RDIR"` subshell — a relative redirect target
# would silently land inside the rootfs dir instead of next to
# the script, and ukify would fail to find it.
INITRD=$(realpath -m "./chimera-rescue-${VARIANT}-${DATE}-initrd.zst")
OUT=$(realpath -m "./$OUT")
TMP_TAR=$(realpath -m "/tmp/mkrescue-${VARIANT}-discard-$$.tar.gz")

# CRITICAL: set ROOT_DIR globally NOW so any mount_pseudo /
# umount_pseudo call (from lib.sh) targets the chroot, not the
# host's /.  An earlier version of this script set ROOT_DIR
# inside the per-step blocks AFTER calling mount_pseudo —
# resulting in `mount -t devtmpfs none /dev` on the build host,
# which clobbered the devpts mount on /dev/pts and broke pty
# allocation system-wide until reboot or a manual
# `doas mount -t devpts devpts /dev/pts`.  Set-it-once-up-front
# defends against the same bug recurring.
ROOT_DIR="$RDIR"

# ---- cleanup trap -------------------------------------------------

cleanup() {
    rc=$?
    set +e
    sync
    umount_pseudo
    rm -f "$TMP_TAR"
    exit "$rc"
}
trap cleanup INT TERM EXIT

# ---- step 1: build the rootfs via mkrootfs.sh ---------------------
#
# We piggy-back on mkrootfs.sh's apk-into-dir scaffolding.  Its
# tarball output is thrown away (we don't need a tarball; we need
# the populated directory) but its bootstrap, install, and
# post-install cleanup are reused.

msg "Building rescue rootfs at $RDIR (variant=$VARIANT)..."
MKROOTFS_ROOT_DIR="$RDIR" \
MKROOTFS_CACHE_DIR=$(realpath ./apk-cache) \
    ./mkrootfs.sh \
        -b base-bootstrap \
        -p "$PKGS $EXTRA_PKGS" \
        -o "$TMP_TAR" \
        -f rescue-${VARIANT} \
    || die "mkrootfs.sh failed"

# Discard the tarball — we only wanted the populated directory.
rm -f "$TMP_TAR"
TMP_TAR=

# ---- step 2: reinstall chimerautils -------------------------------
#
# mkrootfs.sh unconditionally `apk del chimerautils` at the end as
# a bootstrap-cleanup step.  For a rescue image we very much want
# chimerautils' basic utilities present; re-add it now.

msg "Re-adding chimerautils (mkrootfs.sh removes it post-install)..."
mount_pseudo
chroot "$RDIR" /usr/bin/apk add --no-interactive chimerautils \
    || die "chimerautils re-add failed"
umount_pseudo

# ---- step 3: empty root password ----------------------------------
#
# Rescue image is for diagnostic console access; the operator
# needs a shell immediately, no password handshake.  Anyone with
# console access to a VM running this image already has the
# operational equivalent of root, so an empty password is
# honest about the threat model.  The image is NEVER for
# production-shaped use.

msg "Setting empty root password..."
mount_pseudo
chroot "$RDIR" /usr/bin/passwd -d root \
    || die "passwd -d root failed"
umount_pseudo

# ---- step 3a: set hostname to "rescue" ---------------------------
#
# mkrootfs.sh defaults the hostname to "chimera" if /usr/bin/init
# is present.  Overwrite to "rescue" so the login banner reads
# "rescue login:" — operator sees at a glance which image they
# booted into when context-switching between cloud and rescue VMs.

msg "Setting hostname to 'rescue'..."
echo rescue > "${RDIR}/etc/hostname"

# ---- step 4: auto-login getty services for all 3 consoles --------
#
# Write one dinit service per console (tty1, ttyS0, hvc0); each
# spawns agetty with --autologin root + --noclear so the operator
# sees a root shell on whichever console qemu/libvirt wires up.
# Chimera's nyagetty-dinit-links would auto-detect from cmdline,
# but for a rescue image we want ALL three consoles live
# regardless of what the firmware passed.

msg "Writing per-console auto-login getty services..."
for tty in tty1 ttyS0 hvc0; do
    case "$tty" in
        hvc0|ttyS0) BAUD=115200 ;;
        tty1)       BAUD=38400 ;;
    esac
    cat > "${RDIR}/etc/dinit.d/rescue-getty-${tty}" <<EOF
# Auto-login root getty for ${tty}.  Written by mkrescue.sh.
# depends-on = login.target matches what Chimera's stock
# nyagetty-dinit's agetty + agetty-service files use.  Don't
# depend on 'boot' — boot.d/<svc> symlinks add an implicit
# boot→svc dep, and a svc→boot dep would close the cycle.
type = process
command = /sbin/agetty --autologin root --noclear -L ${tty} ${BAUD} vt100
restart = true
restart-delay = 2.0
depends-on = login.target
EOF
    mkdir -p "${RDIR}/etc/dinit.d/boot.d"
    ln -sf "/etc/dinit.d/rescue-getty-${tty}" \
        "${RDIR}/etc/dinit.d/boot.d/rescue-getty-${tty}"
done

# Disable the stock nyagetty auto-detect agetty — it would race
# our explicit per-console services and risk double-getty on a tty.
rm -f "${RDIR}/etc/dinit.d/boot.d/agetty"

# ---- step 5: write /init for kernel-to-userspace handoff ---------
#
# When the kernel unpacks the cpio initramfs into the initial
# tmpfs rootfs, it looks for /init and execs it as PID 1.  For
# Chimera we want to chain into dinit (/usr/bin/init).  But dinit
# expects certain pseudo-filesystems mounted; mount them here
# first so dinit doesn't have to.
#
# This /init replaces /init from the rootfs (which may be a
# symlink to /usr/bin/init from dinit-chimera, but we want the
# explicit pseudo-mount step before dinit takes over).

cat > "${RDIR}/init" <<'EOF'
#!/bin/sh
# Rescue image PID-1 stub.  Mounts the kernel-expected pseudo
# filesystems then execs dinit.

mount -t devtmpfs none /dev    2>/dev/null
mount -t proc     none /proc   2>/dev/null
mount -t sysfs    none /sys    2>/dev/null
mkdir -p /run
mount -t tmpfs    none /run    2>/dev/null
mkdir -p /tmp
mount -t tmpfs    none /tmp    2>/dev/null

# Sanity: did dinit-chimera land /usr/bin/init?
if [ ! -x /usr/bin/init ]; then
    echo "rescue: /usr/bin/init missing; dropping to emergency shell" >&2
    exec /bin/sh
fi

exec /usr/bin/init
EOF
chmod 0755 "${RDIR}/init"

# ---- step 6: enable network + diagnostics services ----------------

msg "Enabling supporting services..."
for svc in sshd dhcpcd chronyd; do
    [ -e "${RDIR}/usr/lib/dinit.d/$svc" ] || continue
    ln -sf "/lib/dinit.d/$svc" "${RDIR}/etc/dinit.d/boot.d/$svc"
done

# ---- step 7: detect kernel version --------------------------------

KERNVER=$(ls "${RDIR}/usr/lib/modules" 2>/dev/null | sort -V | tail -1)
[ -n "$KERNVER" ] || die "no kernel modules in rescue rootfs"
KERNEL="${RDIR}/boot/vmlinuz-${KERNVER}"
[ -r "$KERNEL" ] || die "missing kernel image at $KERNEL"
msg "Kernel: $KERNVER"

# ---- step 8: cpio + zstd the whole rootfs as the initramfs -------

msg "Packing rootfs into cpio.zst..."
( cd "$RDIR" && find . -print0 \
    | cpio --null --create --format=newc 2>/dev/null \
    | zstd -T0 -19 \
    > "$INITRD" ) \
    || die "cpio | zstd failed"

# POSIX-portable size: `wc -c < file` works under chimerautils
# (BSD-style) and GNU alike.  `du -h` is also POSIX and gives
# human-readable.
INITRD_SIZE=$(du -h "$INITRD" | awk '{print $1}')
msg "Initramfs: $INITRD ($INITRD_SIZE)"

# ---- step 9: build the UKI via ukify ------------------------------
#
# Kernel cmdline writes dmesg to all three consoles.  Last
# console= becomes /dev/console for early init writes; we put
# hvc0 last because that's what the cloud image uses and matches
# the Tilley automation harness expectations.

CMDLINE="rw console=tty0 console=ttyS0,115200 console=hvc0 panic=0"

msg "Building UKI: $OUT"
ukify build \
    --linux="$KERNEL" \
    --initrd="$INITRD" \
    --cmdline="$CMDLINE" \
    --output="$OUT" \
    || die "ukify build failed"

OUT_SIZE=$(du -h "$OUT" | awk '{print $1}')
msg "Done: $OUT ($OUT_SIZE)"
msg ""
msg "Usage: drop $OUT onto an ESP at /EFI/rescue/rescue.efi (or"
msg "similar), select from firmware boot manager.  Boots into a"
msg "root shell on tty1 + ttyS0 + hvc0; password-free for emergency"
msg "console access.  Includes apk + chimera-installer for nuke-and-"
msg "pave install onto attached storage."
