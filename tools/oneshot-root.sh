#!/usr/bin/env bash
# One-shot turing_unlock trial for the RTX 2070 SUPER (TU104, 0000:07:00.0).
#
# Leaves the stock boot untouched: installs the module + pinned firmware, builds
# a SEPARATE initramfs that loads turing_unlock, adds a non-default GRUB entry
# that passes turing_unlock.targets=0000:07:00.0, and arms it for ONE boot with
# grub-reboot. The boot after that is the normal Arch entry again.
# It does not reboot. Undo with: sudo ./oneshot-root.sh --remove
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
BDF=0000:07:00.0
KVER=$(uname -r)
FWDIR=/usr/lib/firmware/turing-unlock/610.43.03
MODDST=/usr/lib/modules/$KVER/updates/turing_unlock.ko
CONF=/etc/mkinitcpio-turing-unlock.conf
IMG=/boot/initramfs-linux-turing-unlock.img
GRUBD=/etc/grub.d/42_turing_unlock
ENTRY=turing-unlock-oneshot

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

if [[ ${1:-} == --remove ]]; then
    rm -f "$GRUBD" "$CONF" "$IMG" "$MODDST"
    rm -rf /usr/lib/firmware/turing-unlock
    depmod "$KVER"
    grub-editenv - unset next_entry
    grub-mkconfig -o /boot/grub/grub.cfg
    echo "removed; stock boot only"
    exit 0
fi

# --- Preconditions -----------------------------------------------------------
pkgver=$(pacman -Q linux | awk '{print $2}')
[[ ${pkgver/.arch/-arch} == "$KVER" ]] ||
    die "installed linux ($pkgver) != running kernel ($KVER); reboot into the new kernel and rebuild the module first"
[[ $(cat /sys/bus/pci/devices/$BDF/vendor):$(cat /sys/bus/pci/devices/$BDF/device) == 0x10de:0x1e84 ]] ||
    die "$BDF is not the RTX 2070 SUPER (10de:1e84)"
[[ $(modinfo -F vermagic "$KIT/turing_unlock.ko") == "$KVER "* ]] || die "module vermagic does not match $KVER"
(cd "$KIT" && sha256sum -c --quiet module.sha256) || die "module hash mismatch"
(cd "$KIT/assets" && sha256sum -c --quiet ../assets.sha256) || die "firmware hash mismatch"

# --- Module + firmware -------------------------------------------------------
install -Dm644 "$KIT/turing_unlock.ko" "$MODDST"
depmod "$KVER"
install -d "$FWDIR"
(cd "$KIT/assets" && install -m644 ./*.bin "$FWDIR/")

# --- Separate initramfs (stock /boot/initramfs-linux.img is not touched) -----
# -c makes mkinitcpio ignore /etc/mkinitcpio.conf.d drop-ins. The fsck hook is
# dropped: root is btrfs, no fsck.btrfs exists (btrfs-progs not installed), so
# the hook adds nothing but makes mkinitcpio exit 1 ("errors were encountered").
sed -E -e 's/^MODULES=\(.*\)$/MODULES=(turing_unlock)/' \
       -e '/^HOOKS=/s/ fsck\b//' /etc/mkinitcpio.conf > "$CONF"
grep -qx 'MODULES=(turing_unlock)' "$CONF" || die "could not set MODULES in $CONF"
grep -qE '^HOOKS=.*\bfsck\b' "$CONF" && die "could not drop fsck hook in $CONF"
mkinitcpio -k "$KVER" -c "$CONF" -g "$IMG"
listing=$(lsinitcpio "$IMG")
grep -q "turing_unlock.ko" <<<"$listing" || die "module missing from $IMG"
for f in "$KIT"/assets/*.bin; do
    grep -q "turing-unlock/610.43.03/$(basename "$f")" <<<"$listing" || die "$(basename "$f") missing from $IMG"
done

# --- GRUB entry: copy of the stock 'Arch Linux' entry + the target ----------
# Parameters come from the running kernel's command line.
params=$(sed -E 's/(^| )(BOOT_IMAGE|turing_unlock\.[a-z]+)=[^ ]+//g; s/^ +//' /proc/cmdline)
espuuid=$(findmnt -no UUID /boot)
cat > "$GRUBD" <<EOF
#!/bin/sh
cat <<'GRUB'
menuentry 'Arch Linux (turing_unlock one-shot, $BDF)' --id $ENTRY {
	load_video
	set gfxpayload=keep
	insmod gzio
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $espuuid
	linux	/vmlinuz-linux $params turing_unlock.targets=$BDF
	initrd	/$(basename "$IMG")
}
GRUB
EOF
chmod 755 "$GRUBD"
grub-mkconfig -o /boot/grub/grub.cfg
grub-script-check /boot/grub/grub.cfg
grep -q -- "--id $ENTRY" /boot/grub/grub.cfg || die "entry not in grub.cfg"

# --- Arm exactly one boot ----------------------------------------------------
grub-reboot "$ENTRY"
grub-editenv list | grep -qx "next_entry=$ENTRY" || die "next_entry not set"
echo
echo "Armed: the NEXT boot only uses '$ENTRY'; the one after is stock again."
echo "Best is a cold boot: sudo poweroff, wait ~10 s, power on (sudo reboot also works)."
echo "Disarm without rebooting: sudo grub-editenv - unset next_entry"
