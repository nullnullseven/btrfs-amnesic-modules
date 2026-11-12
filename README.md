How to enable modules:

- disable disk swap (if use it) and run scripts with `sudo`
- scripts install modules with these kernel options:

`ramovl` (overlay in tmpfs),

`diskovl` and `diskovl.size=<GB>` (overlay in dm-crypt container),

`zramroot` and `zramroot.size=<GB>` (zram block device)

- systemd-boot: in the menu press Space, select the entry, press e, append  `option` to the end and press Enter.
- GRUB: in the menu press e, append  `option`  to the linux line and press Ctrl+X.

Verification on the desktop:

`findmnt -no FSTYPE /`

`findmnt -no FSTYPE /home`

`cat /run/ramroot.log` (logs for `ramovl`)

`cat /run/diskroot.log` (logs for `diskovl`)

`cat /run/zramroot.log` and `sudo zramctl` (logs for `ramovl`)
