#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Enable hibernation on Arch Linux so the Hibernate entry appears in KDE
# Plasma (and anything else that asks systemd-logind's CanHibernate).
#
# Handles: swap partition or swapfile (ext4/xfs/btrfs), GRUB / systemd-boot /
# UKI (/etc/kernel/cmdline), mkinitcpio (udev or systemd hooks) / dracut,
# LVM and LUKS (resume after encrypt/lvm2), and logind's ProtectHome when the
# swapfile lives under /home. Also keeps python-validity fingerprint readers
# working after resume.
#
# Usage:  sudo ./enable-hibernate.sh [--dry-run]
# Env:    SWAPFILE=/swapfile   where to create a swapfile (default /swapfile)
#         SIZE=<n>G            swapfile size (default: RAM size, rounded up)
#         USE_PARTITION=0      ignore an existing swap partition
set -euo pipefail

DRY=0
[[ ${1:-} == --dry-run || ${1:-} == -n ]] && DRY=1
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n 3,16p "$0"; exit 0; }

say()  { printf '\e[1m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[33mwarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }
run()  { if ((DRY)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }
backup() { [[ -f $1 && ! -f $1.pre-hibernate ]] && run cp -a "$1" "$1.pre-hibernate"; return 0; }

((DRY)) || [[ $EUID -eq 0 ]] || die "run as root (or with --dry-run to preview)"
[[ -f /etc/arch-release ]] || warn "not Arch Linux; continuing, but paths may differ"

# --- preflight ----------------------------------------------------------------
grep -qw disk /sys/power/state || die "kernel does not support hibernation (/sys/power/state)"
if [[ -r /sys/kernel/security/lockdown ]] && ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
	die "kernel lockdown is active ($(cat /sys/kernel/security/lockdown)); hibernation is blocked (often Secure Boot)"
fi

RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_G=$(( (RAM_KB + 1048575) / 1048576 ))

# --- 1. pick or create swap -------------------------------------------------------
RESUME_DEV="" RESUME_OFFSET="" SWAPFILE=${SWAPFILE:-/swapfile}

if [[ ${USE_PARTITION:-1} == 1 ]]; then
	while read -r name type size _; do
		[[ $type == partition && $name != /dev/zram* ]] || continue
		(( size >= RAM_KB / 2 )) || continue          # kernel compresses the image (image_size ~2/5 RAM)
		RESUME_DEV=$name; break
	done < <(tail -n +2 /proc/swaps)
fi

if [[ -n $RESUME_DEV ]]; then
	say "using existing swap partition $RESUME_DEV"
	UUID=$(blkid -s UUID -o value "$RESUME_DEV" || true)
else
	SIZE=${SIZE:-${RAM_G}G}
	FSTYPE=$(findmnt -no FSTYPE -T "$(dirname "$SWAPFILE")" || true)
	say "swapfile $SWAPFILE ($SIZE) on $FSTYPE"
	if [[ ! -f $SWAPFILE ]]; then
		NEED_G=${SIZE%G}
		[[ $NEED_G =~ ^[0-9]+$ ]] || die "SIZE must be in whole gigabytes, e.g. SIZE=16G"
		FREE_G=$(( $(df --output=avail -k "$(dirname "$SWAPFILE")" | tail -1) / 1048576 ))
		(( FREE_G >= NEED_G + 2 )) || die "only ${FREE_G}G free on $(dirname "$SWAPFILE"); need ${NEED_G}G (+2G margin). Set SWAPFILE= to a bigger filesystem (e.g. SWAPFILE=/home/swapfile) or a smaller SIZE="
		case $FSTYPE in
			btrfs) run btrfs filesystem mkswapfile --size "$SIZE" "$SWAPFILE" ;;
			ext4|xfs|f2fs) run mkswap --size "$SIZE" --file "$SWAPFILE" ;;
			*) die "swapfiles on $FSTYPE are not supported for hibernation" ;;
		esac
	else
		say "$SWAPFILE already exists, reusing it"
	fi
	if ! grep -q "^$SWAPFILE[[:space:]]" /etc/fstab; then
		backup /etc/fstab
		if ((DRY)); then echo "    [dry-run] append to /etc/fstab: $SWAPFILE none swap defaults,pri=10 0 0"
		else echo "$SWAPFILE none swap defaults,pri=10 0 0" >> /etc/fstab; fi
	fi
	grep -q "^$SWAPFILE " /proc/swaps || run swapon -p 10 "$SWAPFILE"

	UUID=$(findmnt -no UUID -T "$(dirname "$SWAPFILE")" || true)
	if [[ -f $SWAPFILE ]]; then
		case $FSTYPE in
			btrfs) RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAPFILE" 2>/dev/null || true) ;;
			*)     RESUME_OFFSET=$(filefrag -v "$SWAPFILE" 2>/dev/null | awk '$1=="0:" {sub(/\.\./,"",$4); print $4}' || true) ;;
		esac
	fi
	((DRY)) && [[ -z $RESUME_OFFSET ]] && RESUME_OFFSET="<computed when run as root>"
	[[ -n $RESUME_OFFSET ]] || die "could not determine resume_offset for $SWAPFILE"
fi
[[ -n $UUID ]] || die "could not determine the UUID of the resume device"

ARGS="resume=UUID=$UUID"
[[ -n $RESUME_OFFSET ]] && ARGS="$ARGS resume_offset=$RESUME_OFFSET"
say "kernel parameters: $ARGS"

# --- 2. kernel command line --------------------------------------------------------
strip_resume() { sed -E 's/ ?resume(_offset)?=[^ "]*//g'; }
CMDLINE_DONE=0

if [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null; then
	say "bootloader: GRUB"
	backup /etc/default/grub
	if ((DRY)); then
		echo "    [dry-run] GRUB_CMDLINE_LINUX_DEFAULT += $ARGS; grub-mkconfig -o /boot/grub/grub.cfg"
	else
		sed -i -E 's/ ?resume(_offset)?=[^ "]*//g' /etc/default/grub
		sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $ARGS\"|" /etc/default/grub
		GRUB_CFG=$(find /boot /efi -path '*/grub/grub.cfg' 2>/dev/null | head -1 || true)
		grub-mkconfig -o "${GRUB_CFG:-/boot/grub/grub.cfg}"
	fi
	CMDLINE_DONE=1
fi

if [[ -f /etc/kernel/cmdline ]]; then
	say "UKI / kernel-install: /etc/kernel/cmdline"
	backup /etc/kernel/cmdline
	NEW="$(strip_resume < /etc/kernel/cmdline | tr -s ' ') $ARGS"
	if ((DRY)); then echo "    [dry-run] /etc/kernel/cmdline -> $NEW"; else echo "$NEW" > /etc/kernel/cmdline; fi
	CMDLINE_DONE=1
fi

ESP=$(bootctl --print-esp-path 2>/dev/null || true)
if [[ -n $ESP && -d $ESP/loader/entries ]] && ls "$ESP"/loader/entries/*.conf >/dev/null 2>&1; then
	say "bootloader: systemd-boot entries in $ESP/loader/entries"
	for e in "$ESP"/loader/entries/*.conf; do
		grep -q '^options' "$e" || continue
		backup "$e"
		if ((DRY)); then echo "    [dry-run] $e: options += $ARGS"
		else sed -i -E "/^options/{s/ ?resume(_offset)?=[^ ]*//g; s|$| $ARGS|}" "$e"; fi
	done
	CMDLINE_DONE=1
fi

((CMDLINE_DONE)) || warn "no GRUB, systemd-boot or /etc/kernel/cmdline found: add '$ARGS' to your kernel command line yourself"

# --- 3. initramfs ----------------------------------------------------------------------
if [[ -f /etc/mkinitcpio.conf ]] && command -v mkinitcpio >/dev/null; then
	HOOKS_LINE=$(grep -E '^HOOKS=' /etc/mkinitcpio.conf)
	if grep -qw systemd <<<"$HOOKS_LINE"; then
		say "mkinitcpio uses the systemd hook: resume is handled by systemd-hibernate-resume"
	elif grep -qw resume <<<"$HOOKS_LINE"; then
		say "mkinitcpio already has the resume hook"
	else
		say "mkinitcpio: adding the resume hook before 'filesystems'"
		backup /etc/mkinitcpio.conf
		if ((DRY)); then echo "    [dry-run] HOOKS: insert resume before filesystems"
		else sed -i -E '/^HOOKS=/ s/\bfilesystems\b/resume filesystems/' /etc/mkinitcpio.conf; fi
	fi
	grep -E '^HOOKS=' /etc/mkinitcpio.conf | sed 's/^/    /'
	run mkinitcpio -P
elif command -v dracut >/dev/null; then
	say "dracut: the resume module is included when resume= is set; regenerating"
	run dracut --regenerate-all --force
else
	warn "no mkinitcpio or dracut found: make sure your initramfs can resume"
fi

# --- 4. logind and /home -----------------------------------------------------------
if [[ -z $RESUME_DEV && $SWAPFILE == /home/* ]]; then
	say "swapfile is under /home: giving systemd-logind read-only access (ProtectHome)"
	D=/etc/systemd/system/systemd-logind.service.d
	if ((DRY)); then echo "    [dry-run] write $D/hibernate-swapfile.conf (ProtectHome=read-only)"
	else
		mkdir -p "$D"
		printf '[Service]\nProtectHome=read-only\n' > "$D/hibernate-swapfile.conf"
		systemctl daemon-reload
	fi
fi

# --- 5. python-validity fingerprint readers -----------------------------------------------
# The sensor drops its TLS session when powered off, but the daemon's stop before
# sleep can lose a race with a start job, so it may be frozen into the image still
# holding the old session; after resume every request fails (<cmd< 0404).
# Always restart it on resume.
if systemctl cat python3-validity.service >/dev/null 2>&1; then
	say "python-validity found: installing a sleep hook that restarts it on resume"
	HOOK=/etc/systemd/system-sleep/python-validity
	if ((DRY)); then echo "    [dry-run] write $HOOK"
	else
		mkdir -p "${HOOK%/*}"
		cat > "$HOOK" <<'EOF'
#!/bin/sh
# Restart python-validity across suspend/hibernate (installed by enable-hibernate.sh).
# The pre-sleep stop can be cancelled by a racing start job, so post always
# does a full stop/reset/start: the sensor loses its TLS session on power-off.
case "$1" in
  pre)
    systemctl stop open-fprintd.service python3-validity.service || true
    ;;
  post)
    systemctl stop open-fprintd.service python3-validity.service || true
    for id in 138a:0090 138a:0097 138a:009d 06cb:009a; do
      usbreset "$id" >/dev/null 2>&1 || true
    done
    sleep 1
    systemctl reset-failed python3-validity.service || true
    systemctl --no-block start python3-validity.service open-fprintd.service
    ;;
esac
exit 0
EOF
		chmod 755 "$HOOK"
	fi
	command -v usbreset >/dev/null || warn "usbreset not found (package usbutils); the hook will skip the USB reset"
fi

say "done$( ((DRY)) && echo ' (dry run, nothing changed)')"
echo "Reboot, then check:  busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate"
echo "It should print: s \"yes\". Backups end in .pre-hibernate"
