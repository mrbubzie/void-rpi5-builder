#!/bin/sh
set -eu

release=6.12.18-voidpi5test
bundle=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
action=${1:-stage}
boot=${2:-/boot}
assets=/usr/lib/$release
state=$boot/$release
config=$boot/config.txt

fail() { printf '%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo."
grep -aq 'raspberrypi,5-model-b' /proc/device-tree/compatible ||
    fail "This installer requires a Raspberry Pi 5 Model B running with a device tree."
[ "$(findmnt -nr -o FSTYPE --mountpoint "$boot")" = vfat ] ||
    fail "Pass the mounted FAT boot partition as the second argument."
[ -f "$config" ] || fail "No config.txt on $boot."

replace_config() {
    cp -- "$1" "$state/config.pending"
    sync
    mv -f -- "$state/config.pending" "$config"
    sync
}

case "$action" in
    stage)
        [ ! -e "$state" ] || fail "Boot staging directory already exists: $state"
        if grep -Eiq '^[[:space:]]*(include[[:space:]]|os_prefix[[:space:]]*=|overlay_prefix[[:space:]]*=|device_tree[[:space:]]*=)' "$config"; then
            fail "Custom boot paths or includes found. See OFFLINE.md for manual staging."
        fi
        (cd "$bundle" && sha256sum -c SHA256SUMS)
        arch=$(xbps-uhelper arch)
        [ -f "$bundle/repository/$arch-repodata" ] || fail "Wrong XBPS architecture: $arch"
        if ! command -v dracut >/dev/null || ! command -v depmod >/dev/null; then
            xbps-install -i --repository="$bundle/initramfs-dependencies" dracut kmod
        fi
        xbps-install -i --repository="$bundle/repository" rpi5-kernel-test
        depmod "$release"

        temporary=$(mktemp -d "$boot/voidpi5-stage.XXXXXX")
        trap 'rm -rf -- "$temporary"' EXIT
        cp -- "$assets/kernel.img" "$assets/bcm2712-rpi-5-b.dtb" "$temporary/"
        cp -R -- "$assets/overlays" "$temporary/"
        dracut --force "$temporary/initramfs.img" "$release"
        test -s "$temporary/initramfs.img"
        cp -- "$config" "$temporary/config.original"
        {
            printf '[all]\noverlay_prefix=%s/overlays/\n' "$release"
            awk 'tolower($0) !~ /^[[:space:]]*(kernel[[:space:]]*=|auto_initramfs[[:space:]]*=|initramfs[[:space:]]+)/ { print }' "$config"
            printf '\n[all]\narm_64bit=1\nkernel=%s/kernel.img\n' "$release"
            printf 'device_tree=%s/bcm2712-rpi-5-b.dtb\n' "$release"
            printf 'auto_initramfs=0\ninitramfs %s/initramfs.img followkernel\n' "$release"
        } > "$temporary/config.test"
        mv -T -- "$temporary" "$state"
        trap - EXIT
        sync
        printf 'Staged %s. Review %s/config.test before activation.\n' "$release" "$state"
        ;;
    activate)
        [ -f "$state/config.test" ] || fail "Stage the kernel first."
        cmp -s "$config" "$state/config.original" ||
            fail "config.txt differs from the saved original. Review the staged configuration first."
        for file in kernel.img initramfs.img bcm2712-rpi-5-b.dtb; do
            [ -s "$state/$file" ] || fail "Missing staged file: $file"
        done
        replace_config "$state/config.test"
        printf 'Test kernel selected for the next reboot.\n'
        ;;
    rollback)
        [ -f "$state/config.original" ] || fail "No saved boot configuration."
        cmp -s "$config" "$state/config.test" ||
            fail "config.txt differs from the staged test config. Restore config.original manually after reviewing the changes."
        replace_config "$state/config.original"
        printf 'Original boot configuration restored for the next reboot.\n'
        ;;
    *) fail "Usage: $0 [stage|activate|rollback] [/boot]" ;;
esac
