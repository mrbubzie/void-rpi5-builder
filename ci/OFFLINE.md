# Install the 6.12.18 test kernel offline

Use an already bootable 64-bit Void Linux installation on a Raspberry Pi 5
Model B, with native Raspberry Pi firmware boot and its existing Wi-Fi and
Bluetooth firmware. The test intentionally uses the firmware currently
installed on the Pi. Keep access to the FAT boot partition from a second
computer or spare boot medium before activating the test.

Extract the inner tarball and enter its directory. Run:

```sh
sha256sum -c SHA256SUMS
sudo sh ./install-on-pi.sh stage /boot
```

Use `/boot/firmware` in place of `/boot` if that is the mounted FAT partition.
Staging installs the kernel package and creates a matching initramfs using
the Pi's settings. If needed, the installer offers to install dracut and kmod
from the bundled dependency repository. Review that transaction before
accepting. The test uses an independent kernel filename and stores the boot
configuration it will use in `/boot/6.12.18-voidpi5test/config.test`.

If your current config selects a custom overlay, review that it is present
under the staged `overlays/` directory and is compatible with 6.12.18.
Review the full staged configuration before activating it:

```sh
sudo sh ./install-on-pi.sh activate /boot
sudo reboot
```

Confirm the kernel and compare Bluetooth enumeration:

```sh
uname -r
getconf PAGESIZE
bluetoothctl list
sudo dmesg | grep -Ei 'bluetooth|hci0|brcmfmac|firmware'
```

Expect `6.12.18-voidpi5test` and `16384`. If Bluetooth still fails, keep the
output so you can compare the kernel and firmware messages from both boots.

To restore the original boot selection:

```sh
sudo sh ./install-on-pi.sh rollback /boot
sudo reboot
```

If the test fails to boot, mount the FAT partition on another computer and
copy `6.12.18-voidpi5test/config.original` over `config.txt` at the root of the
partition. If your config uses includes, custom prefixes, a custom DTB, or
UEFI, configure the test manually for your boot layout. The packaged image,
DTB and overlays are under `/usr/lib/6.12.18-voidpi5test` after installation.
Use `dracut --force <initramfs-path> 6.12.18-voidpi5test` to generate its initramfs.

The optional headers expose the standard external module build directory.
Install them only if you need to build an external kernel module:

```sh
sudo xbps-install -i --repository="$PWD/repository" rpi5-kernel-test-headers
```

After booting back into your original kernel, you can remove the test
packages with `sudo xbps-remove rpi5-kernel-test` and, if installed,
`sudo xbps-remove rpi5-kernel-test-headers`. The separately staged files
on the FAT partition can then be removed.
