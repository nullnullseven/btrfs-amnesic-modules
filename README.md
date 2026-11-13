How to enable modules:

- disable disk swap (if use it) and run scripts with `sudo`
- scripts install modules with these kernel options:

`ramovl` (overlay in tmpfs),

`diskovl` and `diskovl.size=<GB>` (overlay in dm-crypt container),

`zramroot` and `zramroot.size=<GB>` (zram block device)

- systemd-boot: in the menu press e, append  `option` to the end and press Enter.
- GRUB: in the menu press e, append  `option`  to the linux line and press Ctrl+X.

Verification on the desktop:

`findmnt -no FSTYPE /`

`findmnt -no FSTYPE /home`

`cat /run/ramroot.log` (logs for `ramovl`)

`cat /run/diskroot.log` (logs for `diskovl`)

`cat /run/zramroot.log` and `sudo zramctl` (logs for `zramroot`)

.bashrc theme:

<img width="795" height="343" alt="1" src="https://github.com/user-attachments/assets/ff05aaf5-9428-4f5f-a8c4-b3918472e0cd" />

