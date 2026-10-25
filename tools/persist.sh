#!/usr/bin/env bash
# Make the RTX 2070 SUPER unlock permanent. Run as bay (NOT with sudo):
# makepkg refuses root and calls sudo itself.
#
#  1. removes the one-shot trial (its module/firmware/initramfs/GRUB entry)
#  2. installs dkms + btrfs-progs (the latter gives the fsck hook its helper, so
#     mkinitcpio -P stops exiting 1 during package install/kernel updates)
#  3. builds + installs nlzy/turing-unlock's Arch packages (DKMS module rebuilt
#     on every kernel update, pinned firmware, mkinitcpio drop-in), which
#     regenerates the normal initramfs with turing_unlock in it
#  4. adds turing_unlock.targets=0000:07:00.0 to GRUB_CMDLINE_LINUX_DEFAULT.
#     The "Advanced options > fallback/recovery" style entries only use
#     GRUB_CMDLINE_LINUX, so they stay stock; or press 'e' in GRUB and delete
#     the parameter for a one-off stock boot.
# Undo: ./persist.sh --remove
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo "run as your user, not root" >&2; exit 1; }

KIT=$(cd "$(dirname "$0")" && pwd)
SRC=$KIT/nlzy-turing-unlock   # created by ./prepare.sh
PARAM=turing_unlock.targets=0000:07:00.0

if [[ ${1:-} == --remove ]]; then
    sudo sed -i -E "s/ ?$PARAM//" /etc/default/grub
    sudo pacman -Rns --noconfirm turing-unlock-dkms turing-unlock-firmware
    sudo mkinitcpio -P || true
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    echo "removed; next boot is stock"
    exit 0
fi

[[ $(git -C "$SRC" rev-parse HEAD) == 1d379b724454d6fb7e8a7a8dd0ea359febc05ca3 ]] ||
    { echo "turing-unlock checkout is not the tested commit 1d379b7" >&2; exit 1; }

sudo "$KIT/oneshot-root.sh" --remove
sudo pacman -S --needed --noconfirm dkms btrfs-progs linux-headers
(cd "$SRC/packaging/arch" && makepkg -sif --noconfirm)
sudo mkinitcpio -P

# DKMS must have built the module for the running kernel, and the stock image must carry it.
dkms status turing-unlock | grep -q "$(uname -r).*installed" || { echo "dkms build missing" >&2; exit 1; }
lsinitcpio /boot/initramfs-linux.img | grep -q turing_unlock.ko || { echo "module not in initramfs" >&2; exit 1; }
lsinitcpio /boot/initramfs-linux.img | grep -q turing-unlock/610.43.03/v67-tu102-610.43.03.bin ||
    { echo "firmware not in initramfs" >&2; exit 1; }

grep -q "$PARAM" /etc/default/grub ||
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $PARAM\"/" /etc/default/grub
grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
grep -q "$PARAM" /boot/grub/grub.cfg || { echo "parameter not in grub.cfg" >&2; exit 1; }
echo
echo "Permanent. Every boot now unlocks before nvidia loads. Check after reboot: ./verify.sh"
