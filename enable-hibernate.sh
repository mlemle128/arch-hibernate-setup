#!/bin/bash
# Enable hibernation on Arch Linux (GRUB + mkinitcpio, LVM): disk swapfile on /home + resume= in GRUB + resume hook.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

SWAP=/home/swapfile
SIZE=32G

# 1. Swapfile (low priority so zram is still used first for normal swapping)
if [[ ! -f $SWAP ]]; then
    mkswap --size "$SIZE" --file "$SWAP"
fi
grep -q "^$SWAP " /etc/fstab || echo "$SWAP none swap defaults,pri=10 0 0" >> /etc/fstab
swapon -p 10 "$SWAP" 2>/dev/null || true

# 2. Resume device + offset
UUID=$(findmnt -no UUID -T "$SWAP")
OFFSET=$(filefrag -v "$SWAP" | awk '$1=="0:" {sub(/\.\./,"",$4); print $4}')
echo "resume=UUID=$UUID resume_offset=$OFFSET"

# 3. GRUB cmdline (replace any old resume args)
cp /etc/default/grub /etc/default/grub.bak
sed -i -E 's/ ?resume(_offset)?=[^ "]*//g' /etc/default/grub
sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=$UUID resume_offset=$OFFSET\"|" /etc/default/grub
grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# 4. resume hook after lvm2 (LV must be active before resume)
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak
grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf || sed -i -E 's/^(HOOKS=.*\blvm2)\b/\1 resume/' /etc/mkinitcpio.conf
grep ^HOOKS /etc/mkinitcpio.conf
mkinitcpio -P

# 5. logind runs with ProtectHome=yes, so it can't see a swapfile under /home
#    and CanHibernate returns ENOENT. Give it read-only access.
if [[ $SWAP == /home/* ]]; then
    mkdir -p /etc/systemd/system/systemd-logind.service.d
    printf '[Service]\nProtectHome=read-only\n' > /etc/systemd/system/systemd-logind.service.d/hibernate-swapfile.conf
    systemctl daemon-reload
fi

echo "Done. Reboot, then Hibernate will appear in the Plasma menu."
