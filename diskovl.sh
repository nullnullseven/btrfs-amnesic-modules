#!/bin/bash
# diskovl.sh - creates and installs the dracut diskroot module:
# the entire system runs in an overlay, with the upper layer in an ephemeral encrypted container ON DISK (not in RAM).
# The size of the upper layer is limited by the available disk space, not by RAM.
# Supports btrfs subvolumes from fstab (each gets its own overlay) and roots without subvolumes.
# Run: sudo bash diskovl.sh
# To enable the mode, add diskovl to the kernel parameters at boot.
# Container size (optional): diskovl.size=<GB>, default 20

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

for b in dracut cryptsetup losetup mkfs.ext4 shred dd; do
    if ! command -v "$b" >/dev/null 2>&1; then
        echo "Program not found: $b (install it and try again)" >&2
        exit 1
    fi
done

MODDIR=/usr/lib/dracut/modules.d
MOD=$MODDIR/94diskroot

echo "==> Looking for old modules with a diskovl hook"
BACKUP=/root/dracut-modules-backup
for d in "$MODDIR"/*/; do
    d=${d%/}
    [ "$d" = "$MOD" ] && continue
    if grep -rqs "diskovl" "$d" 2>/dev/null; then
        mkdir -p "$BACKUP"
        name=$(basename "$d")
        short=${name#[0-9][0-9]}
        echo "    moving $d to $BACKUP/ (conflicts with the diskovl parameter)"
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
    hostonly='' instmods overlay btrfs ext4 jbd2 mbcache crc16 crc32c_generic loop dm_mod dm-crypt xts aes_generic aesni_intel sha256_generic 2>/dev/null || true
}
install() {
    inst_multiple cryptsetup losetup mkfs.ext4 dd modprobe mount umount shred rm chmod mkdir
    inst_multiple -o setfattr getfattr chattr
    inst_hook pre-pivot 10 "$moddir/diskroot.sh"
}
SETUP_EOF

cat > "$MOD/diskroot.sh" <<'HOOK_EOF'
#!/bin/sh
. /lib/dracut-lib.sh
if ! getargbool 0 diskovl ; then
    return
fi

LOG=/run/diskroot.log
KEY=/dev/shm/overlay-key
LOOP_DEV=
IMG=

# SELinux: copy the label of the lower-layer directory ($1) to the upper-layer directory ($2)
diskroot_label() {
    command -v getfattr >/dev/null 2>&1 || return 0
    command -v setfattr >/dev/null 2>&1 || return 0
    L=$(getfattr --only-values -n security.selinux "$1" 2>/dev/null) || return 0
    [ -n "$L" ] || return 0
    setfattr -n security.selinux -v "$L" "$2" 2>/dev/null
    return 0
}

diskroot_cleanup() {
    umount /cow 2>/dev/null
    cryptsetup close diskovlcrypt 2>/dev/null
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null
    shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
    [ -n "$IMG" ] && rm -f "$IMG"
    umount /live/disk 2>/dev/null
}

diskroot_main() {
    [ -n "$NEWROOT" ] || NEWROOT=/sysroot
    echo "== diskroot: starting, NEWROOT=$NEWROOT"

    if getargbool 0 ramovl || getargbool 0 cryptovl || getargbool 0 zramroot; then
        echo "another mode is set (ramovl/cryptovl/zramroot); skipping diskovl"
        return 0
    fi

    SIZE=$(getarg diskovl.size=)
    case "$SIZE" in ""|*[!0-9]*) SIZE=20 ;; esac
    echo "container size: ${SIZE} GB"

    modprobe overlay || { echo "overlay module is unavailable"; return 1; }
    modprobe loop 2>/dev/null
    modprobe dm-crypt 2>/dev/null

    # Root device and filesystem type
    DEV=$(getarg root=)
    DEV=${DEV#block:}
    RFS=
    while read -r s m t rest; do
        if [ "$m" = "$NEWROOT" ]; then
            RFS=$t
            [ -b "$DEV" ] || DEV=$s
        fi
    done < /proc/mounts
    echo "DEV=$DEV, root type: $RFS"
    [ -b "$DEV" ] || { echo "could not find the root device; nothing changed"; return 1; }

    # 1. Choose where the container file will be stored (root is writable; do not change the ro flag)
    mkdir -p /live/disk
    if [ "$RFS" = "btrfs" ]; then
        mount -t btrfs -o noatime,subvolid=5 "$DEV" /live/disk \
            || { echo "could not mount the btrfs top level"; return 1; }
        IMG=/live/disk/.diskovl.img
    else
        mount --bind "$NEWROOT" /live/disk || { echo "root bind mount failed"; return 1; }
        mkdir -p /live/disk/var/tmp
        IMG=/live/disk/var/tmp/.diskovl.img
    fi
    echo "container file: $IMG"
    rm -f "$IMG"

    # 2. Prepare the encrypted container BEFORE touching the root
    dd if=/dev/urandom bs=64 count=1 of="$KEY" status=none || { echo "could not create the key"; diskroot_cleanup; return 1; }
    chmod 600 "$KEY"
    : > "$IMG"
    command -v chattr >/dev/null 2>&1 && chattr +C "$IMG" 2>/dev/null
    dd if=/dev/zero of="$IMG" bs=1M count=0 seek=$((SIZE*1024)) status=none \
        || { echo "could not create the container file"; diskroot_cleanup; return 1; }
    LOOP_DEV=$(losetup -f --show "$IMG") \
        || { echo "losetup failed"; diskroot_cleanup; return 1; }
    # Remove the filename immediately: data remains accessible through the loop device; space is freed at shutdown
    rm -f "$IMG"
    IMG=
    cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 \
        --hash sha256 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --batch-mode --key-file "$KEY" "$LOOP_DEV" \
        || { echo "luksFormat failed"; diskroot_cleanup; return 1; }
    cryptsetup open --type luks2 --allow-discards --key-file "$KEY" "$LOOP_DEV" diskovlcrypt \
        || { echo "cryptsetup open failed"; diskroot_cleanup; return 1; }
    mkfs.ext4 -F -q -m 0 -O ^has_journal -E lazy_itable_init=1,nodiscard /dev/mapper/diskovlcrypt \
        || { echo "mkfs failed"; diskroot_cleanup; return 1; }
    mkdir -p /cow
    mount -o noatime,nodiratime,nobarrier /dev/mapper/diskovlcrypt /cow \
        || { echo "could not mount the container"; diskroot_cleanup; return 1; }
    mkdir -p /cow/work /cow/rw
    echo "container is ready"

    # 3. Move the root out of the way
    mkdir -p /live/image
    mount --bind "$NEWROOT" /live/image || { echo "bind mount failed"; diskroot_cleanup; return 1; }
    umount "$NEWROOT" || { echo "umount failed"; umount /live/image; diskroot_cleanup; return 1; }
    diskroot_label /live/image /cow/rw

    mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/image,upperdir=/cow/rw,workdir=/cow/work,default_permissions,relatime overlay "$NEWROOT" \
        || { echo "root overlay failed; rolling back"; mount --bind /live/image "$NEWROOT"; diskroot_cleanup; return 1; }
    echo "root overlay is ready"

    # 4. btrfs subvolumes from fstab: each gets its own overlay, with its upper layer in the same container
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
           && diskroot_label /live/sub$n /cow/rw$n \
           && mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/sub$n,upperdir=/cow/rw$n,workdir=/cow/work$n,default_permissions,relatime overlay "$NEWROOT$mp"; then
            echo "ok: $mp"
        else
            echo "FAILED: $mp; leaving it in fstab (it will be mounted from disk)"
            echo "$spec $mp $fstype $opts $rest" >> /run/fstab.new
        fi
    done < /live/image/etc/fstab

    cat /run/fstab.new > "$NEWROOT/etc/fstab" && echo "fstab replaced"

    mkdir -p "$NEWROOT/live/cow" "$NEWROOT/live/image"
    diskroot_label /live/image "$NEWROOT/live"
    diskroot_label /live/image "$NEWROOT/live/cow"
    diskroot_label /live/image "$NEWROOT/live/image"
    mount --bind /cow/rw "$NEWROOT/live/cow"
    mount --bind /live/image "$NEWROOT/live/image"

    shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
    echo "key removed from RAM; the container cannot be decrypted without it"
    echo "== diskroot: finished"
}

diskroot_main >> "$LOG" 2>&1
echo "diskroot: hook finished; log is at $LOG" > /dev/kmsg
HOOK_EOF

chmod +x "$MOD/module-setup.sh" "$MOD/diskroot.sh"

echo "==> Enabling the module in the configuration"
mkdir -p /etc/dracut.conf.d
echo 'add_dracutmodules+=" diskroot "' > /etc/dracut.conf.d/diskroot.conf

echo "==> Building a test image (verification)"
dracut -f /tmp/diskroot-test.img "$(uname -r)"
if lsinitrd /tmp/diskroot-test.img | grep -q "10-diskroot.sh"; then
    echo "    hook 10-diskroot.sh is in the image: OK"
else
    echo "    ERROR: hook is not in the image" >&2
    rm -f /tmp/diskroot-test.img
    exit 1
fi
echo "    pre-pivot hooks in the image:"
lsinitrd /tmp/diskroot-test.img | grep "hooks/pre-pivot/" | sed 's/^/      /'
rm -f /tmp/diskroot-test.img

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

Done. How to enable disk upper-layer mode:
  - systemd-boot: press e, append diskovl and press Enter.
  - GRUB: press e in the menu, append diskovl to the linux line, then press Ctrl+X.
  To use a different container size: diskovl diskovl.size=40   (GB)

IMPORTANT: The size must not exceed the available disk space. The file is sparse and only uses
space as data is written, but if the disk fills up before the container is "full,"
the system inside will not know this in advance and will start reporting write errors.

Check from the desktop:
  cat /run/diskroot.log
  findmnt -no FSTYPE /       (overlay)
  findmnt -no FSTYPE /home   (overlay)
  df -h /                    (size = diskovl.size)

To reclaim space after deleting large files during a session: sudo fstrim -v /

Without the diskovl parameter the system boots as usual.
DONE
