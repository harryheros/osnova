# OsNova Changelog

Releases, newest first.

## 2.3.2 (2026-11-23)

- **Ubuntu: safer final write on small hosts.** The cloud image is written
  over the same disk that holds the downloaded image file, so that file has
  to be read from memory, not from blocks the write has already replaced.
  The write now uses direct I/O, which keeps the gigabytes being written out
  of the page cache so they cannot push the image file out of memory, and
  the file is read once beforehand so it starts out cached. Disks that
  refuse direct I/O get the previous buffered write.
- Offline tests (`tests/test_reinstall.sh`) for the address, route, disk and
  password helpers, the image write, the version and this changelog; a CI
  workflow runs them with `bash -n` and ShellCheck on every push.
- The script is ShellCheck-clean; changelog headings carry release dates.
- No changes to options or defaults.

## 2.3.1 (2026-11-03)

- Shorter README; the release history moved to `CHANGELOG.md`.
- No changes to installation behaviour.

## 2.3.0 (2026-09-25)

Fixes for installations that failed on some providers / source systems:

- **Wrong disk could be erased**: the target used to be the first non-removable disk in name order (hd*, nvme*, sd*, vd*), so a VPS booting from vda with an extra NVMe/sd* data disk had the *data disk* overwritten. The target is now derived from the running root filesystem (partitions, LVM, RAID, LUKS, Btrfs subvolumes); `--disk` overrides it, and roots spanning several disks require it. All disks are shown with the target marked before confirmation.
- **Ubuntu: no network after install**: the netplan file used `match: type: ethernet`, but netplan's `match` only accepts `name`, `macaddress` and `driver` and rejects unknown keys — with the other netplan files deleted and cloud-init networking disabled, nothing configured the NIC. Now matched by MAC address.
- **Multi-NIC hosts**: both paths applied the static IP to *every* Ethernet NIC (`Type=ether`), creating duplicate addresses. The configuration is now bound to the NIC's MAC address (falling back to all Ethernet NICs only when the source interface is not a physical NIC).
- **RHEL-family source systems (CentOS/Rocky/Alma)**: the GRUB entry was generated into `/boot/grub/grub.cfg`, which these systems do not read, so the host simply rebooted into the old OS. The config GRUB actually reads is regenerated (including the ESP on RHEL 7/8 UEFI), and the script verifies the entry exists before rebooting. The boot entry also loads XFS, Btrfs, LVM and RAID modules.
- **Gateways outside the subnet**: on-link routing was only used for /32 and /128; it is now used whenever the gateway lies outside the assigned subnet.
- **Containers**: OpenVZ/LXC/Docker are detected up front with a clear message instead of failing half-way.
- **Hosts without the nbd module** (e.g. Debian's cloud kernel) or without `qemu-nbd` (RHEL's qemu-img package): the Ubuntu path falls back to a raw image on loop devices. CentOS 7 now installs `qemu-img` and `gdisk`.
- **Password check** no longer depends on `grep -P`, which minimal systems lack (every password was rejected there).
- **Broken IPv6** is now disabled in the installed system too (previously only in the installer; the system picked it back up via router advertisements). IPv6 DNS servers are dropped when there is no working IPv6.
- **Route parsing** uses the `via`/`dev` keywords instead of column positions; the IPv6 default route must be on the same interface; temporary/deprecated IPv6 addresses are ignored; link-local gateways are probed with an interface scope.

Safety:

- **Ubuntu**: the image is now written only after the summary and countdown, with the running filesystem remounted read-only first and an immediate reboot afterwards. Previously the old system kept running for the countdown on top of the freshly written image.
- **Debian**: Ctrl+C during the countdown now restores normal booting. Previously the installer entry stayed the GRUB default, so the next reboot — whenever it happened — would start the installer and wipe the disk.
- Pre-flight checks before confirmation: free space in /boot (Debian) and /var/tmp (Ubuntu), disk size (and exact image size for Ubuntu), low-memory warning for the Debian installer.
- `--dns` values are validated.

Updates:

- Ubuntu 26.04 LTS (`-u 26`).
- Debian default changed from 12 to 13 (current stable; 12 is in LTS). Use `-d 12` for the previous default.
- Debian 11 reached end of life on 2026-08-31: a warning is shown, and the installer switches to archive.debian.org automatically once the release is removed from the live mirrors.
- Ubuntu images are verified against Ubuntu's published SHA256SUMS.
- New option `--disk /dev/XXX`.

## 2.2.0 (2026-06-15)

- Fixed Debian installer hang at "Loading additional components / Retrieving *.udeb" on hosts with broken IPv6: the script now probes actual IPv6 reachability and, if an address is present but unroutable (common on budget VPS), disables IPv6 for both the installer (`ipv6.disable=1` on the kernel cmdline) and the installed system — degrading cleanly to IPv4-only. Hosts with working IPv6 keep full dual-stack; IPv4-only hosts are unaffected
- Fixed Debian installer hang by adding an explicit mirror block (`mirror/http/hostname`, `directory`, `suite`) to both the preseed and the kernel command line — previously no mirror was specified, so the installer had no host to fetch udebs from
- Fixed `netcfg/get_nameservers` passing a space-separated DNS list (d-i treats it as a single token, breaking udeb-stage DNS); the installer now uses the first DNS, while the full list is still written into the installed system
- Added `netcfg/get_hostname` and `netcfg/get_domain` to prevent hidden prompts when DNS is unstable
- Made `preseed/late_command` robust: searches multiple known locations for `post-install.sh`, uses `&&` chaining so failures surface, and logs to `/var/log/osnova-postinstall.log` in the target system
- post-install.sh is now staged in multiple initrd locations so it survives regardless of d-i build layout
- Added `partman/early_command` to wipe pre-existing LVM/MD/partition signatures (`vgchange`, `pvremove`, `mdadm --stop`, `wipefs`) plus `partman-lvm/device_remove_lvm` and `partman-md/device_remove_md`, preventing silent partitioner hangs on previously-provisioned disks
- Switched GRUB default selection to the canonical `GRUB_DEFAULT=saved` + `grub-set-default`/`grub-reboot` method and forced `GRUB_DISABLE_SUBMENU=y`, so the installer entry boots reliably even when GRUB builds a submenu
- No user-facing CLI changes — fully compatible with v2.1.0 invocation

## 2.1.0 (2026-05-26)

- Fixed network detection on hosts with multi-IP interfaces (cloud VPS with main IP + alias addresses)
- Fixed mixed IPv4/IPv6 default routes pointing at different interfaces (`ip -4` / `ip -6` now used explicitly)
- Fixed disk detection to use awk exact-equality on the TYPE column instead of substring match
- Added wget `--tries=3 --timeout=30/60` to both Debian netboot and Ubuntu cloud image downloads
- Added qcow2 format pre-check via `qemu-img info` (catches HTML error pages saved as `.img`)
- Ubuntu image download no longer uses `--continue` — stale images from a different release URL are removed first
- Added IPv4 default-route guard: script now aborts cleanly if no default route is detected
- Added qemu-nbd settle delay between disconnect and connect
- Refactored systemd-networkd IPv6 block to use a single pre-built string instead of nested heredoc-in-command-substitution
- No user-facing CLI changes — fully compatible with v2.0.0 invocation

## 2.0.0 (2026-03-31)

- Added root privilege and x86_64 architecture pre-checks
- Added interactive confirmation prompt before disk erasure (`--force` to skip)
- Added `--version` / `-v` parameter
- Added password validation to reject shell-unsafe characters
- Upgraded random password generation to 20 characters with symbols
- Fixed preseed password injection to prevent shell expansion issues
- Fixed SSH port configuration to reliably write Port even when missing from sshd_config
- Fixed GRUB_DISABLE_OS_PROBER repeated append (now idempotent)
- Fixed disk detection fallback to exclude loop, nbd, ram, and zram devices
- Added Ubuntu cloud image integrity verification via qemu-img check
- Added IPv6 /128 on-link route support for both Debian and Ubuntu paths
- Improved cleanup trap to cover HUP/PIPE signals and temporary work directory
- Debian BBR configuration moved to dedicated sysctl.d file
- Debian SSH configuration now uses sshd_config.d override for reliability

## 1.0.0 (2026-03-25)

- Initial release
