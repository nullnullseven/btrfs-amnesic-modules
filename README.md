How to enable RAM mode:
- systemd-boot: in the menu press Space, select the entry, press e, append  `ramovl`  to the end and press Enter.
- GRUB: in the menu press e, append  `ramovl`  to the linux line and press Ctrl+X.

Verification on the desktop:
`cat /run/ramroot.log`
`findmnt -no FSTYPE /`       (should be overlay)
`findmnt -no FSTYPE /home`   (overlay, if /home was a separate subvolume or part of the root)
