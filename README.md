# arch-hibernate-setup

One script that makes **Hibernate** work on Arch Linux and shows it in the
**KDE Plasma** power menu (and anywhere else that asks systemd-logind).

Plasma only shows Hibernate when logind's `CanHibernate` returns `yes`. On many
Arch installs it returns `na`, because:

- the only swap is **zram**, which lives in RAM and can't hold a hibernation image;
- the kernel has no `resume=` / `resume_offset=` parameter, so it can't find the image at boot;
- the initramfs has no **resume** step;
- the swapfile is under `/home`, and **systemd-logind runs with `ProtectHome=yes`**,
  so it can't see the swapfile and reports *"No such file or directory"*.

This script fixes all of those.

## What it does

1. **Swap.** Uses an existing swap partition if one is big enough. Otherwise it
   creates a swapfile (default `/swapfile`, sized to your RAM) with
   priority 10, so zram is still used first for everyday swapping, and adds it
   to `/etc/fstab`. It works on ext4, xfs and **btrfs** (via `btrfs filesystem mkswapfile`).
2. **Kernel command line.** Adds `resume=UUID=…` (and `resume_offset=…` for a
   swapfile) for **GRUB** (regenerates `grub.cfg`), **systemd-boot** entries,
   and **UKIs / kernel-install** (`/etc/kernel/cmdline`).
3. **Initramfs.**
   - **mkinitcpio** with busybox/udev hooks: adds the `resume` hook before
     `filesystems` (so after `encrypt` / `lvm2`), then rebuilds.
   - **mkinitcpio** with the `systemd` hook: nothing to add.
   - **dracut:** regenerates (its resume module is included automatically).
4. **logind.** If the swapfile is under `/home`, adds a drop-in giving
   `systemd-logind` read-only access to `/home`.

Every file it edits is backed up first as `<file>.pre-hibernate`. Running it
again is safe: it reuses the swapfile and replaces old `resume=` arguments.

## Usage

```bash
git clone https://github.com/mlemle128/arch-hibernate-setup
cd arch-hibernate-setup
./enable-hibernate.sh --dry-run        # preview, changes nothing (no root needed)
sudo ./enable-hibernate.sh
reboot
```

Options (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `SWAPFILE` | `/swapfile` | where to create the swapfile, e.g. `SWAPFILE=/home/swapfile` if `/` is small |
| `SIZE` | RAM size | swapfile size in whole GB, e.g. `SIZE=16G` |
| `USE_PARTITION` | `1` | set `0` to ignore an existing swap partition |

```bash
sudo SWAPFILE=/home/swapfile SIZE=32G ./enable-hibernate.sh
```

The script refuses to create a swapfile if the filesystem lacks space for it
(+2 GB margin). A swapfile smaller than RAM usually still works, because the
kernel compresses the image, but RAM-sized is safest.

## Check it worked

After rebooting:

```bash
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate
# s "yes"
```

Hibernate should now be in the Plasma menu. Test it once with your work saved.
If the machine cold-boots instead of resuming:

```bash
journalctl -b -1 | grep -i -E 'hibern|resume|PM:'
cat /proc/cmdline        # resume= and resume_offset= present?
```

## Requirements and limits

- **Secure Boot / kernel lockdown** blocks hibernation. The script stops if
  `/sys/kernel/security/lockdown` is not `[none]`.
- Swapfiles must not be on a filesystem that moves their blocks. On btrfs the
  script uses `mkswapfile`, which creates a NOCOW file.
- If you move or recreate the swapfile, run the script again, because `resume_offset` changes.
- **GNOME** hides Hibernate even when it works. Use an extension, or `systemctl hibernate`.
- **NVIDIA proprietary driver:** usually fine with PRIME render offload. If resume
  shows a black screen, enable NVIDIA's helpers:
  `systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume` and set
  `options nvidia NVreg_PreserveVideoMemoryAllocations=1`.

## Undo

Restore the `*.pre-hibernate` backups, remove the swapfile line from
`/etc/fstab`, delete `/etc/systemd/system/systemd-logind.service.d/hibernate-swapfile.conf`,
then regenerate your bootloader config and initramfs.

## Licence

MIT
