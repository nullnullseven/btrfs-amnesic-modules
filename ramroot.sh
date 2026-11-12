#!/bin/bash
# zramroot.sh - creates and installs the dracut zramroot module:
# the entire system (root + btrfs subvolumes from fstab) is copied to a compressed zram disk in RAM.
# After copying, the system no longer needs the actual disk.
# Run: sudo bash zramroot.sh
# To enable the mode, add zramroot to the kernel parameters at boot.
# Optional: zramroot.size=<GB> (default 50), zramroot.algo=<zstd|lzo-rle|lz4> (default zstd)

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

for b in dracut mkfs.ext4 cp sleep; do
    if ! command -v "$b" >/dev/null 2>&1; then
        echo "Program not found: $b (install it and try again)" >&2
        exit 1
    fi
done

MODDIR=/usr/lib/dracut/modules.d
MOD=$MODDIR/93zramroot

echo "==> Looking for old modules with a zramroot hook"
BACKUP=/root/dracut-modules-backup
for d in "$MODDIR"/*/; do
    d=${d%/}
    [ "$d" = "$MOD" ] && continue
    if grep -rqs "zramroot" "$d" 2>/dev/null; then
        mkdir -p "$BACKUP"
        name=$(basename "$d")
        short=${name#[0-9][0-9]}
        echo "    moving $d to $BACKUP/ (conflicts with the zramroot parameter)"
        mv "$d" "$BACKUP/"
        for f in /etc/dracut.conf /etc/dracut.conf.d/*.conf; do
            [ -f "$f" ] && sed -i "s/ $short / /g" "$f"
        done
    fi
done

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
    hostonly='' instmods zram zstd zstd_compress lzo lzo_rle lz4 btrfs ext4 jbd2 mbcache crc16 crc32c_generic 2>/dev/null || true
}
install() {
    inst_multiple cp mkfs.ext4 modprobe mount umount mkdir cat sleep
    inst_multiple -o setfattr getfattr
    inst_hook pre-pivot 10 "$moddir/zramroot.sh"
}
SETUP_EOF

cat > "$MOD/zramroot.sh" <<'HOOK_EOF'
#!/bin/sh
. /lib/dracut-lib.sh
if ! getargbool 0 zramroot ; then
    return
fi

LOG=/run/zramroot.log

# Copies the SELinux label of directory $1 to directory $2 (needed when selinux=1)
zramroot_label() {
    command -v getfattr >/dev/null 2>&1 || return 0
    command -v setfattr >/dev/null 2>&1 || return 0
    L=$(getfattr --only-values -n security.selinux "$1" 2>/dev/null) || return 0
    [ -n "$L" ] || return 0
    setfattr -n security.selinux -v "$L" "$2" 2>/dev/null
    return 0
}

zramroot_reset() {
    umount /zram 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
}

zramroot_main() {
    [ -n "$NEWROOT" ] || NEWROOT=/sysroot
    echo "== zramroot: starting, NEWROOT=$NEWROOT"

    if getargbool 0 ramovl || getargbool 0 cryptovl; then
        echo "ramovl or cryptovl is set; skipping zramroot"
        return 0
    fi

    SIZE=$(getarg zramroot.size=)
    case "$SIZE" in ""|*[!0-9]*) SIZE=50 ;; esac
    ALGO=$(getarg zramroot.algo=)
    [ -n "$ALGO" ] || ALGO=zstd
    echo "disk size: ${SIZE} GB, compression: $ALGO"

    # Root device: first from root= on the command line, then from /proc/mounts
    DEV=$(getarg root=)
    DEV=${DEV#block:}
    if [ ! -b "$DEV" ]; then
        DEV=
        while read -r s m rest; do
            [ "$m" = "$NEWROOT" ] && DEV=$s
        done < /proc/mounts
    fi
    echo "DEV=$DEV"
    [ -n "$DEV" ] || { echo "could not find the root device; nothing changed"; return 1; }

    # 1. Prepare the zram disk (do not touch the root yet)
    modprobe zram || { echo "zram module is unavailable"; return 1; }
    if [ ! -b /dev/zram0 ] && [ -e /sys/class/zram-control/hot_add ]; then
        cat /sys/class/zram-control/hot_add > /dev/null
    fi
    i=0
    while [ ! -b /dev/zram0 ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
    [ -b /dev/zram0 ] || { echo "/dev/zram0 is unavailable"; return 1; }

    echo "$ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null || echo "algorithm $ALGO was not accepted; keeping the default"
    echo "${SIZE}G" > /sys/block/zram0/disksize || { echo "could not set disksize"; return 1; }
    mkfs.ext4 -F -q -m 0 -O ^has_journal -E nodiscard /dev/zram0 \
        || { echo "mkfs failed"; zramroot_reset; return 1; }
    mkdir -p /zram
    mount -o noatime,nodiratime /dev/zram0 /zram \
        || { echo "could not mount zram"; zramroot_reset; return 1; }
    echo "zram is ready"

    # 2. Copy the root
    echo "copying the root..."
    cp -ax "$NEWROOT"/. /zram/ || { echo "root copy failed (not enough space?)"; zramroot_reset; return 1; }
    zramroot_label "$NEWROOT" /zram
    echo "root copied"

    # 3. Copy btrfs subvolumes from fstab
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
        mkdir -p /live/sub$n "/zram$mp"
        if mount -t btrfs -o "$opts,ro" "$DEV" /live/sub$n \
           && cp -ax /live/sub$n/. "/zram$mp/"; then
            zramroot_label /live/sub$n "/zram$mp"
            echo "copied: $mp"
        else
            echo "FAILED: $mp; leaving it in fstab (it will be mounted from disk)"
            echo "$spec $mp $fstype $opts $rest" >> /run/fstab.new
        fi
        umount /live/sub$n 2>/dev/null
    done < /zram/etc/fstab

    # Check whether the SELinux labels were preserved
    A=$(getfattr --only-values -n security.selinux "$NEWROOT/etc/fstab" 2>/dev/null)
    B=$(getfattr --only-values -n security.selinux /zram/etc/fstab 2>/dev/null)
    if [ "$A" = "$B" ]; then echo "SELinux labels: match"; else echo "WARNING: SELinux labels do not match ($A / $B)"; fi

    cat /run/fstab.new > /zram/etc/fstab && echo "fstab replaced"

    # 4. Switch the root: first hide the actual root, then mount zram
    mkdir -p /live/image
    mount --bind "$NEWROOT" /live/image || { echo "bind mount failed"; zramroot_reset; return 1; }
    umount "$NEWROOT" || { echo "umount failed"; umount /live/image; zramroot_reset; return 1; }
    umount /zram
    mount -o noatime,nodiratime /dev/zram0 "$NEWROOT" \
        || { echo "could not mount zram as root; rolling back"; mount --bind /live/image "$NEWROOT"; zramroot_reset; return 1; }
    umount /live/image 2>/dev/null
    echo "== zramroot: finished; system is running from zram, disk is not in use"
}

echo "zramroot: copying the system to zram; this will take some time..." > /dev/kmsg
zramroot_main >> "$LOG" 2>&1
echo "zramroot: hook finished; log is at $LOG" > /dev/kmsg
HOOK_EOF

chmod +x "$MOD/module-setup.sh" "$MOD/zramroot.sh"

echo "==> Enabling the module in the configuration"
mkdir -p /etc/dracut.conf.d
echo 'add_dracutmodules+=" zramroot "' > /etc/dracut.conf.d/zramroot.conf

echo "==> Building a test image (verification)"
dracut -f /tmp/zramroot-test.img "$(uname -r)"
if lsinitrd /tmp/zramroot-test.img | grep -q "10-zramroot.sh"; then
    echo "    hook 10-zramroot.sh is in the image: OK"
else
    echo "    ERROR: hook is not in the image" >&2
    rm -f /tmp/zramroot-test.img
    exit 1
fi
echo "    pre-pivot hooks in the image:"
lsinitrd /tmp/zramroot-test.img | grep "hooks/pre-pivot/" | sed 's/^/      /'
rm -f /tmp/zramroot-test.img

echo "==> Installing the image for boot"
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
    echo "    bootloader not detected: update its configuration manually"
fi

cat <<'DONE'

Done. How to enable zram mode:
  - systemd-boot: press e, append zramroot and press Enter.
  - GRUB: press e in the menu, append zramroot to the linux line, then press Ctrl+X.
  Booting will take longer than usual: the entire system is copied to RAM.
  To use a different disk size: zramroot zramroot.size=40   (GB)

Check from the desktop:
  cat /run/zramroot.log
  findmnt -no SOURCE,FSTYPE /       (/dev/zram0 ext4)
  zramctl                           (actual RAM usage)

Without the zramroot parameter the system boots as usual.
DONE
