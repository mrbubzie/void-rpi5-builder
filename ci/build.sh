#!/usr/bin/env bash
set -euo pipefail

commit=9e61a31dd4b1f2c4a7112c71320781c32673cc52
archive_sha=57e1dd07ae7deff9878dea321405315f1da3651bcb757b9bc55619d566108ffc
version=6.12.18
release=$version-voidpi5test
arch=$(xbps-uhelper arch)
case "$arch" in
    aarch64|aarch64-musl) ;;
    *) echo "Expected native Void ARM64, got $arch" >&2; exit 1 ;;
esac

xbps-install -Suy
xbps-install -Suy
xbps-install -y base-devel bc bison ca-certificates curl elfutils-devel flex kmod \
    ncurses-devel openssl-devel perl python3 rsync tar xz zstd

work=$(mktemp -d)
bundle=$work/void-pi5-$version-$arch
repo=$bundle/repository
deps=$bundle/initramfs-dependencies
mkdir -p "$repo" "$deps" "$work/src" "$work/dep-root/var/db/xbps/keys"

# Seed the temporary XBPS root with the container's trusted Void signing keys.
cp -a /var/db/xbps/keys/. "$work/dep-root/var/db/xbps/keys/"
xbps-install -S -D -y -i -r "$work/dep-root" -c "$deps" \
    -R https://repo-default.voidlinux.org/current/aarch64 dracut kmod
xbps-rindex -a "$deps"/*.xbps

curl -fLSs --retry 3 \
    "https://codeload.github.com/raspberrypi/linux/tar.gz/$commit" -o "$work/linux.tar.gz"
printf '%s  %s\n' "$archive_sha" "$work/linux.tar.gz" | sha256sum -c
tar -xzf "$work/linux.tar.gz" -C "$work/src" --strip-components=1
rm "$work/linux.tar.gz"
cd "$work/src"

export ARCH=arm64 KBUILD_BUILD_USER=voidpi5 KBUILD_BUILD_HOST=github-actions
test "$(make -s kernelversion)" = "$version"
make bcm2712_defconfig
scripts/config --set-str LOCALVERSION '-voidpi5test' -d LOCALVERSION_AUTO \
    -d DEBUG_INFO -e DEBUG_INFO_NONE -d WERROR -e BLK_DEV_INITRD \
    -m BT -m BT_HCIUART -e BT_HCIUART_BCM -m BRCMFMAC -e BRCMFMAC_SDIO
make olddefconfig
test "$(make -s kernelrelease)" = "$release"
for setting in ARM64_16K_PAGES BLK_DEV_INITRD BT_HCIUART_BCM BRCMFMAC_SDIO; do
    grep -Fx "CONFIG_$setting=y" .config
done
grep -Fx 'CONFIG_BT_HCIUART=m' .config
grep -Fx 'CONFIG_BRCMFMAC=m' .config
make -j"$(nproc)" Image.gz modules dtbs

kernel=$work/kernel
headers=$work/headers
assets=$kernel/usr/lib/$release
mkdir -p "$assets/overlays" "$headers/usr/src/$release" \
    "$headers/usr/lib/modules/$release"

# Stage modules under Void's canonical /usr/lib/modules path.
ln -s usr/lib "$kernel/lib"
make INSTALL_MOD_PATH="$kernel" INSTALL_MOD_STRIP=1 modules_install
rm "$kernel/lib"
rm -f "$kernel/usr/lib/modules/$release/build" \
    "$kernel/usr/lib/modules/$release/source"
chmod 755 "$kernel/usr/lib/modules/$release"
depmod -b "$kernel/usr" -F System.map "$release"
install -m644 arch/arm64/boot/Image.gz "$assets/kernel.img"
install -m644 System.map .config "$assets/"
install -m644 arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb "$assets/"
install -m644 arch/arm64/boot/dts/overlays/*.dtbo \
    arch/arm64/boot/dts/overlays/README "$assets/overlays/"
install -m644 arch/arm64/boot/dts/overlays/{overlay_map,hat_map}.dtb \
    "$assets/overlays/"

# Preserve generated headers and native Kbuild helpers.
header_tree=$headers/usr/src/$release
rsync -a --exclude='.git*' --exclude='*.o' --exclude='*.cmd' \
    include scripts "$header_tree/"
mkdir -p "$header_tree/arch/arm64" "$header_tree/tools"
rsync -a arch/arm64/include "$header_tree/arch/arm64/"
rsync -a tools/include "$header_tree/tools/"
cp -a .config Makefile Kbuild Module.symvers "$header_tree/"
cp -a arch/arm64/Makefile "$header_tree/arch/arm64/"
ln -s "../../../src/$release" "$headers/usr/lib/modules/$release/build"

# Verify the headers can build an external module.
mkdir "$work/smoke"
printf 'obj-m := smoke.o\n' > "$work/smoke/Makefile"
cat > "$work/smoke/smoke.c" <<'MODULE'
#include <linux/module.h>
MODULE_LICENSE("GPL");
MODULE
make -C "$header_tree" M="$work/smoke" modules
test -s "$work/smoke/smoke.ko"

cd "$repo"
xbps-create -A "$arch" -n "rpi5-kernel-test-${version}_1" \
    -s 'Raspberry Pi 5 test kernel 6.12.18' "$kernel"
xbps-create -A "$arch" -n "rpi5-kernel-test-headers-${version}_1" \
    -s 'External module headers for Raspberry Pi 5 test kernel 6.12.18' "$headers"
xbps-rindex -a ./*.xbps
xbps-query -i -R --repository="$repo" -p pkgver rpi5-kernel-test
xbps-query -i -R --repository="$repo" -p pkgver rpi5-kernel-test-headers

install -m755 /ci/install-on-pi.sh "$bundle/"
install -m644 /ci/OFFLINE.md "$bundle/"
printf 'Kernel commit: %s\nSource SHA-256: %s\nXBPS architecture: %s\n' \
    "$commit" "$archive_sha" "$arch" > "$bundle/BUILD-INFO.txt"
cd "$bundle"
sha256sum repository/* initramfs-dependencies/* install-on-pi.sh \
    OFFLINE.md BUILD-INFO.txt > SHA256SUMS
cd "$work"
tar -czf "/output/${bundle##*/}.tar.gz" "${bundle##*/}"