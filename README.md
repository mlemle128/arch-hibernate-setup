# arch-hibernate-setup

Enables hibernation on an Arch Linux machine that only has zram swap, so the
**Hibernate** option shows up in the KDE Plasma (or any logind-aware) power menu.

Plasma hides Hibernate when `CanHibernate` is `na`, which happens when there is
no disk-backed swap big enough to hold RAM. zram doesn't count — it lives in RAM.

## What it does

1. Creates a 32 GB swapfile at `/home/swapfile` (priority 10, so zram is still
   preferred for everyday swapping) and adds it to `/etc/fstab`.
2. Adds `resume=UUID=… resume_offset=…` to `GRUB_CMDLINE_LINUX_DEFAULT` and
   regenerates `/boot/grub/grub.cfg`.
3. Adds the `resume` hook after `lvm2` in `/etc/mkinitcpio.conf` and rebuilds
   the initramfs.

Backups are written to `/etc/default/grub.bak` and `/etc/mkinitcpio.conf.bak`.

## Assumptions

- GRUB bootloader, busybox/udev-based mkinitcpio hooks (not the `systemd` hook)
- `/home` is ext4 (swapfile offset is found with `filefrag`)
- Kernel lockdown / Secure Boot is off (`cat /sys/kernel/security/lockdown` shows `[none]`)

Edit `SWAP` and `SIZE` at the top of the script to suit your system.

## Usage

```bash
sudo ./enable-hibernate.sh
reboot
```

Test it by hibernating and powering back on. If it cold-boots instead of
resuming, check:

```bash
journalctl -b -1 | grep -i -E 'hibern|resume|PM:'
```

## Licence

MIT
