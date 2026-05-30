#!/bin/sh
#
# Convenience script for generating cloud-flavoured rootfs tarballs
# for Chimera Linux.  Same shape as mkrootfs-platform.sh but with a
# fixed package set tuned for libvirt/qemu cloud VMs with cloud-init
# datasource support.  Output is a single rootfs tarball that feeds
# mkcloud.sh's -c {serial,video} variants — the package set is
# identical between variants; only runtime config differs.
#
# All extra arguments are passed to mkrootfs.sh as is.
#
# Usage: ./mkrootfs-cloud.sh [-p "extra packages"] [mkrootfs.sh args]
#
# License: BSD-2-Clause
#

EXTRA_PKGS=

while getopts "p:" opt; do
    case "$opt" in
        p) EXTRA_PKGS="$OPTARG";;
        *) ;;
    esac
done

shift $((OPTIND - 1))

# Cloud-VM package set.  Chimera ships dinit service files in
# separate -dinit subpackages (not in the main package); install
# both so we have the daemon binaries AND the service files.
#
# We deliberately do NOT install the *-dinit-links subpackages
# (chrony-dinit-links, dbus-dinit-links, nyagetty-dinit-links).
# Those auto-enable services at apk-install time by writing
# boot.d/ symlinks.  mkcloud.sh owns symlink-writing explicitly
# in step 13 so the enable-at-boot story is grep-visible from
# one place — silent auto-enables make it harder to reason about
# what runs at boot.  Cost: one extra symlink per service in
# mkcloud.sh; benefit: a single source of truth for the boot.d
# population.
PKGS="base-full \
linux-stable \
linux-stable-zfs-bin \
initramfs-tools \
limine \
cloud-init cloud-init-dinit \
python-jinja2 \
openssh openssh-dinit \
dhcpcd dhcpcd-dinit \
chrony chrony-dinit \
acpid acpid-dinit \
qemu-guest-agent qemu-guest-agent-dinit \
nyagetty-dinit \
ca-certificates \
zfs zfs-dinit zfs-udev \
dbus"

exec ./mkrootfs.sh \
    -p "$PKGS $EXTRA_PKGS" \
    -f cloud \
    "$@"
