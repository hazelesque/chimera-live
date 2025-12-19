#!/bin/sh
#
# Convenience script for generating releases - this generates all relevant
# images for the given platform so that they can be published
#
# all arguments are passed to the respective commands
#
# Copyright 2022 q66 <q66@chimera-linux.org>
#
# License: BSD-2-Clause
#

APK_BIN="apk"

if ! command -v "$APK_BIN" > /dev/null 2>&1; then
    echo "ERROR: invalid apk command"
    exit 1
fi

if [ -z "$APK_ARCH" ]; then
    APK_ARCH=$(${APK_BIN} --print-arch)
fi

mkdir -p release-stamps

check_stamp() {
    test -f "release-stamps/stamp-$APK_ARCH-$1"
}

touch_stamp() {
    touch "release-stamps/stamp-$APK_ARCH-$1"
}

die() {
    echo "ERROR: $@"
    exit 1
}

# iso images for every platform

make_iso() {
    local type=$1
    shift
    echo "LIVE: $type"
    if ! check_stamp live-${type}; then
        MKLIVE_BUILD_DIR=build-live-${type}-$APK_ARCH ./mklive-image.sh -b $type -- \
            -a "$APK_ARCH" "$@" || die "failed to build live-$type"
        touch_stamp live-$type
    fi
}

# base iso is always available
make_iso base "$@"

case "$APK_ARCH" in
    ppc|ppc64)
        # bug endian won't support desktops without manual intervention
        ;;
    *)
        make_iso gnome "$@"
        make_iso plasma "$@"
        ;;
esac

# bootstrap and full rootfses for every target

make_rootfs() {
    ROOT_TYPE="$1"
    shift
    echo "ROOTFS: $ROOT_TYPE"
    if ! check_stamp root-$ROOT_TYPE; then
        MKROOTFS_ROOT_DIR=build-root-$ROOT_TYPE-$APK_ARCH ./mkrootfs-platform.sh \
            -P $ROOT_TYPE -- -a "$APK_ARCH" "$@" \
                || die "failed to build root-$ROOT_TYPE"
        touch_stamp root-$ROOT_TYPE
    fi
}

make_rootfs bootstrap "$@"
make_rootfs full "$@"

make_device() {
    make_rootfs "$@"
    echo "DEVICE: $1"
    if ! check_stamp dev-$1; then
        ./mkimage.sh "chimera-linux-${APK_ARCH}-ROOTFS-$(date '+%Y%m%d')-$1.tar.gz" \
            || die "failed to build dev-$1"
        touch_stamp dev-$1
    fi
}

case "$APK_ARCH" in
    aarch64)
        make_device rpi "$@"
        make_device pbp "$@"
        make_device quartzpro64 "$@"
        make_device rock64 "$@"
        make_device rockpro64 "$@"
        ;;
    riscv64)
        make_device unmatched "$@"
        ;;
esac
