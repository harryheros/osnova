# OsNova

> Deterministic OS reinstallation for VPS and bare-metal servers.

[![Version](https://img.shields.io/badge/version-v2.3.2-blue.svg)](https://github.com/harryheros/osnova/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](#license)
[![CI](https://github.com/harryheros/osnova/actions/workflows/ci.yml/badge.svg)](https://github.com/harryheros/osnova/actions/workflows/ci.yml)
[![Arch](https://img.shields.io/badge/arch-x86__64-lightgrey.svg)](#quick-start)
[![Systems](https://img.shields.io/badge/installs-Debian%2011%2F12%2F13%20%7C%20Ubuntu%2022.04%2F24.04%2F26.04-green.svg)](#supported-systems)

[Quick start](#quick-start) · [Options](#options) · [Supported systems](#supported-systems) · [How it works](#how-it-works) · [Changelog](./CHANGELOG.md) · [License](#license)

OsNova reinstalls Debian or Ubuntu from the running system, using only official upstream installers and images — no rescue ISO or recovery environment needed. Network settings are carried over, so the server comes back on the same IP.

Use only on systems you own or are authorized to manage.

> [!WARNING]
> OsNova **erases the target disk**. All data on it is permanently destroyed. The target is the disk holding the running root filesystem; every disk is listed, with the target marked, before you confirm. Ctrl+C during the final countdown aborts safely.

## Quick start

Requirements: root, Bash, x86_64, a full virtual machine (KVM, Xen, VMware, Hyper-V) or bare metal. OpenVZ / LXC containers cannot be reinstalled from inside.

```bash
# Review first
curl -fsSL -o reinstall.sh \
  https://raw.githubusercontent.com/harryheros/osnova/main/os/reinstall.sh
less reinstall.sh

# Debian 13 (default)
bash reinstall.sh

# Ubuntu 24.04 with a password and SSH port
bash reinstall.sh -u 24 -p "YourPassword" --port 2222
```

One-line form, without saving the script first:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harryheros/osnova/main/os/reinstall.sh) -d 13
```

## Options

| Option | What it sets | Default |
|---|---|---|
| `-d 11\|12\|13` | Install Debian | 13 |
| `-u 22\|24\|26` | Install Ubuntu | 24 |
| `-p PASSWORD` | Root password | Random, 20 characters |
| `--port PORT` | SSH port | 22 |
| `--dns "IP1 IP2"` | DNS servers, IPv4 or IPv6 | `8.8.8.8 8.8.4.4` |
| `--disk /dev/XXX` | Target disk | The disk holding `/` |
| `-f`, `--force` | Skip the confirmation prompt | — |
| `-v`, `-h` | Show the version, or help | — |

A generated password is shown before the reboot. `--disk` is required when the root filesystem spans several disks.

Example:

```bash
bash reinstall.sh -u 24 -p "SecurePassword" --port 2222 \
  --dns "1.1.1.1 9.9.9.9" --disk /dev/vda --force
```

**Passwords** may use `A-Z a-z 0-9 ! @ # % ^ * _ + = . -`. Characters that break shell or installer parsing (`` $ ` " ' \ ( ) { } | & ; < > ~ `` and spaces) are rejected.

## Supported systems

- **Debian**: 13 Trixie (default), 12 Bookworm (LTS), 11 Bullseye (end of life, no security updates).
- **Ubuntu**: 26.04 LTS Resolute, 24.04 LTS Noble (default), 22.04 LTS Jammy.

Works from Debian, Ubuntu and RHEL-family hosts (CentOS, Rocky, Alma), on BIOS and UEFI.

## How it works

**Debian**: downloads the official netboot installer, adds an automated preseed, boots into it once through a temporary GRUB entry, and installs unattended.

**Ubuntu**: downloads the official cloud image, verifies it against Ubuntu's `SHA256SUMS`, configures it (password, SSH, network, DNS), then writes it over the disk with direct I/O and reboots.

Both paths:

- Reuse the current static IPv4, and IPv6 when it works; broken IPv6 is disabled instead of hanging the install.
- Bind the network configuration to the NIC's MAC address, safe on multi-NIC hosts.
- Route the gateway on-link when it lies outside the subnet (e.g. /32, /128).
- Enable root SSH login with password, and FQ + BBR.
- Check free space, disk size and memory before asking for confirmation.

Tested on KVM virtual machines and common cloud VPS providers, BIOS and UEFI.

Release history: [CHANGELOG.md](./CHANGELOG.md).

## License

[GPL-3.0](./LICENSE): free to use, modify and share; modified versions you distribute stay under GPL-3.0.

Part of the [Nova infrastructure toolkit](https://github.com/harryheros).
