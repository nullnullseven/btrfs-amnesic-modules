#!/bin/bash
# ramovl.sh - creates and connects a dracut module ramroot (whole system in an overlay on tmpfs).
# Enabling the mode: add the word  ramovl  to the kernel parameters at boot

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

if ! command -v dracut >/dev/null 2>&1; then
    echo "dracut not found. This script is intended for systems with dracut (openSUSE, Fedora, etc.)." >&2
    exit 1
fi

MOD=/usr/lib/dracut/modules.d/91ramroot

echo "==> Creating module in $MOD"
mkdir -p "$MOD"

cat > "$MOD/module-setup.sh" <<'SETUP_EOF'
#!/bin/bash
check() {
    return 255
}
depends() {
    return 0
}
installkernel() {
    hostonly='' instmods overlay btrfs
}
install() {
    inst_hook pre-pivot 10 "$moddir/ramroot.sh"
}
SETUP_EOF

cat > "$MOD/ramroot.sh" <<'HOOK_EOF'
#!/bin/sh
. /lib/dracut-lib.sh
if ! getargbool 0 ramovl ; then
    return
fi

LOG=/run/ramroot.log

ramroot_main() {
    echo "== ramroot: start, NEWROOT=$NEWROOT"
    modprobe overlay || { echo "overlay module not available"; return 1; }

    # root device: first from root= in the cmdline, then from /proc/mounts
    DEV=$(getarg root=)
    DEV=${DEV#block:}
    if [ ! -b "$DEV" ]; then
        DEV=
        while read -r s m rest; do
            [ "$m" = "$NEWROOT" ] && DEV=$s
        done < /proc/mounts
    fi
    echo "DEV=$DEV"
    [ -n "$DEV" ] || { echo "could not find root device, exiting, nothing changed"; return 1; }

    # move the root aside
    mkdir -p /live/image
    mount --bind "$NEWROOT" /live/image || { echo "bind failed"; return 1; }
    umount "$NEWROOT" || { echo "umount failed"; return 1; }

    mkdir -p /cow
    mount -n -t tmpfs -o mode=0755,size=50%,nr_inodes=500k,nodev,nosuid,noatime,nodiratime tmpfs /cow \
        || { echo "tmpfs failed, rolling back"; mount --bind /live/image "$NEWROOT"; return 1; }
    mkdir -p /cow/work /cow/rw

    mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/image,upperdir=/cow/rw,workdir=/cow/work,default_permissions,relatime overlay "$NEWROOT" \
        || { echo "root overlay failed, rolling back"; mount --bind /live/image "$NEWROOT"; return 1; }
    echo "root overlay ready"

    # btrfs subvolumes from fstab: each gets its own overlay
    n=0
    : > /run/fstab.new
    while read -r spec mp fstype opts rest; do
        case "$spec" in ""|\#*) continue ;; esac
        if [ "$fstype" != "btrfs" ]; then
            echo "$spec $mp $fstype $opts $rest" >> /run/fstab.new
            continue
        fi
        [ "$mp" = "/" ] && continue
        [ "$mp" = "/.snapshots" ] && continue

        n=$((n+1))
        mkdir -p /live/sub$n /cow/work$n /cow/rw$n "$NEWROOT$mp"
        if mount -t btrfs -o "$opts" "$DEV" /live/sub$n \
           && mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/sub$n,upperdir=/cow/rw$n,workdir=/cow/work$n,default_permissions,relatime overlay "$NEWROOT$mp"; then
            echo "ok: $mp"
        else
            echo "FAILED: $mp, keeping it in fstab (will be mounted from disk)"
            echo "$spec $mp $fstype $opts $rest" >> /run/fstab.new
        fi
    done < /live/image/etc/fstab

    cat /run/fstab.new > "$NEWROOT/etc/fstab" && echo "fstab replaced"

    mkdir -p "$NEWROOT/live/image"
    mount --bind /live/image "$NEWROOT/live/image"
    echo "== ramroot: done"
}

ramroot_main >> "$LOG" 2>&1
echo "ramroot: hook finished, log in $LOG" > /dev/kmsg
HOOK_EOF

chmod +x "$MOD/module-setup.sh" "$MOD/ramroot.sh"

echo "==> Enabling module in the dracut config"
mkdir -p /etc/dracut.conf.d
echo 'add_dracutmodules+=" ramroot "' > /etc/dracut.conf.d/ramroot.conf

echo "==> Test image build (verification)"
dracut -f /tmp/ramroot-test.img "$(uname -r)"
if lsinitrd /tmp/ramroot-test.img | grep -q "10-ramroot.sh"; then
    echo "    hook 10-ramroot.sh present in image: OK"
else
    echo "    ERROR: hook not found in image" >&2
    rm -f /tmp/ramroot-test.img
    exit 1
fi
echo "    pre-pivot hooks in the image:"
lsinitrd /tmp/ramroot-test.img | grep "hooks/pre-pivot/" | sed 's/^/      /'
rm -f /tmp/ramroot-test.img

echo "==> Installing image into the bootloader"
if command -v sdbootutil >/dev/null 2>&1; then
    sdbootutil mkinitrd
elif command -v update-grub >/dev/null 2>&1; then
    dracut -f
    update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    dracut -f
    if [ -d /boot/grub2 ]; then grub2-mkconfig -o /boot/grub2/grub.cfg; fi
elif command -v grub-mkconfig >/dev/null 2>&1; then
    dracut -f
    grub-mkconfig -o /boot/grub/grub.cfg
else
    dracut -f
    echo "    bootloader not detected: update its config manually"
fi

cat <<'DONE'

Done. How to enable RAM mode:
  - systemd-boot: in the menu press Space, select the entry, press e, append  ramovl  to the end and press Enter.
  - GRUB: in the menu press e, append  ramovl  to the linux line and press Ctrl+X.

Verification on the desktop:
  cat /run/ramroot.log
  findmnt -no FSTYPE /       (should be overlay)
  findmnt -no FSTYPE /home   (overlay, if /home was a separate subvolume or part of the root)

Without the ramovl parameter the system boots as usual.
DONE
