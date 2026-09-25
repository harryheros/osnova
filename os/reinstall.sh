#!/usr/bin/env bash
# ==============================================================================
# Project: OsNova - System Deployment & Reinstallation Engine
# Version: 2.3.0
# Description: BIOS + UEFI compatible automated network installer
#              for Debian and Ubuntu systems on VPS and bare-metal servers.
#
# Author: Harry
# GitHub: https://github.com/harryheros/osnova
# Copyright (C) 2026 Harry
#
# License: GNU General Public License v3.0 (GPL-3.0)
# ==============================================================================

set -e

# --- Color and Formatting ---
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
BOLD='\033[1m'

# --- Defaults ---
OS_TYPE="debian"
RELEASE=""
SSH_PORT="22"
ROOT_PASS=""
VERSION="2.3.0"
TARGET_DISK=""
PASSWORD_WAS_GENERATED=0
DNS_SERVERS="8.8.8.8 8.8.4.4"
FORCE_MODE=0
IPV6_USABLE=1

generate_random_password() {
    tr -dc 'A-Za-z0-9!@#%^*_+=' </dev/urandom | head -c 20
}

# ==============================================================================
# HELPER FUNCTIONS
# (pure detection / validation logic — no side effects. Sourcing the script
#  with OSNOVA_LIB_ONLY=1 loads only these, for testing.)
# ==============================================================================

# --- Validation ---------------------------------------------------------------
# Bash regex instead of `grep -P`: minimal images and some providers' stripped
# templates ship a grep without PCRE, where the old check rejected EVERY
# password.
is_valid_password() {
    [[ "$1" =~ ^[A-Za-z0-9!@#%^*_+=.-]+$ ]]
}

is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "$((10#$o))" -le 255 ] || return 1
    done
}

is_ipv6() {
    # Structural check (hex groups, at most one "::"); full validation is
    # left to the consumers, which reject malformed values loudly.
    local ip="$1"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    local dc="${ip//[^:]/}"; [ "${#dc}" -le 7 ] || return 1
    [ "$(grep -o '::' <<<"$ip" | wc -l)" -le 1 ]
}

# --- IPv4 / IPv6 arithmetic ---------------------------------------------------
ipv4_to_int() {
    local IFS=.; set -- $1
    echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

# ipv4_in_subnet IP PREFIX OTHER  -> true if OTHER is inside IP/PREFIX
ipv4_in_subnet() {
    local ip prefix other mask
    ip=$(ipv4_to_int "$1"); prefix="$2"; other=$(ipv4_to_int "$3")
    [ "$prefix" -eq 0 ] && return 0
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( ip & mask )) -eq $(( other & mask )) ]
}

# Expand an IPv6 address to 8 zero-padded groups (lowercase, no "::").
ipv6_expand() {
    local ip="${1,,}" head tail out="" i n
    local -a h=() t=() g=()
    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"; tail="${ip#*::}"
        [ -n "$head" ] && IFS=: read -ra h <<<"$head"
        [ -n "$tail" ] && IFS=: read -ra t <<<"$tail"
        n=$(( 8 - ${#h[@]} - ${#t[@]} ))
        g=("${h[@]}")
        for ((i=0; i<n; i++)); do g+=("0"); done
        g+=("${t[@]}")
    else
        IFS=: read -ra g <<<"$ip"
    fi
    for i in "${g[@]}"; do out+=$(printf '%04x' "$((16#${i:-0}))"); done
    echo "$out"
}

# ipv6_in_subnet IP PREFIX OTHER
ipv6_in_subnet() {
    local a b prefix="$2" full rem
    a=$(ipv6_expand "$1"); b=$(ipv6_expand "$3")
    full=$(( prefix / 4 )); rem=$(( prefix % 4 ))
    [ "${a:0:full}" = "${b:0:full}" ] || return 1
    [ "$rem" -eq 0 ] && return 0
    local mask=$(( (0xF << (4 - rem)) & 0xF ))
    [ $(( 16#${a:full:1} & mask )) -eq $(( 16#${b:full:1} & mask )) ]
}

# Does the default gateway need an on-link route? v2.2 only handled /32 and
# /128; some providers use a gateway outside the assigned subnet at other
# prefix lengths too (e.g. a /24 address with a gateway in another range),
# where a plain route never comes up and the server is unreachable.
gateway4_needs_onlink() {   # IP PREFIX GW
    [ "$2" = "32" ] && return 0
    ! ipv4_in_subnet "$1" "$2" "$3"
}
gateway6_needs_onlink() {   # IP PREFIX GW
    [ "$2" = "128" ] && return 0
    case "${3,,}" in fe80:*) return 1 ;; esac   # link-local: always on-link
    ! ipv6_in_subnet "$1" "$2" "$3"
}

prefix_to_mask() {
    local i mask=""
    local full_octets=$(($1 / 8))
    local partial_octet=$(($1 % 8))
    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then mask+="255"
        elif [ $i -eq $full_octets ]; then mask+=$((256 - 2**(8-partial_octet)))
        else mask+="0"; fi
        [ $i -lt 3 ] && mask+="."
    done
    echo "$mask"
}

# Value that follows KEY in an `ip route` line ("via", "dev", ...).
route_field() {   # LINE KEY
    awk -v k="$2" '{for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit }}' <<<"$1"
}

# Partition device name: /dev/sda + 1 -> /dev/sda1, /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
part_dev() {
    case "$1" in
        *[0-9]) echo "${1}p${2}" ;;
        *)      echo "${1}${2}" ;;
    esac
}

# --- Environment detection ----------------------------------------------------
# OpenVZ / LXC / Docker cannot replace their own kernel or disk; v2.2 ran
# until something failed half-way. Prints the container type, if any.
detect_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local c; c=$(systemd-detect-virt -c 2>/dev/null) && [ "$c" != "none" ] && { echo "$c"; return 0; }
    fi
    if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then echo "openvz"; return 0; fi
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then echo "docker/podman"; return 0; fi
    if tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then echo "lxc"; return 0; fi
    return 1
}

# The disk that holds the running root filesystem, through partitions, LVM,
# LUKS and MD layers. v2.2 took the first non-removable disk in /sys/block
# name order (hd*, nvme*, sd*, vd*), so a VPS booting from vda with an extra
# NVMe or sd* data disk had the DATA disk wiped instead.
_is_blk() { [ -b "$1" ]; }

detect_root_disk() {
    local src disks
    src=$(findmnt -no SOURCE / 2>/dev/null | head -n1)
    src="${src%%\[*}"                           # btrfs: /dev/vda1[/@] -> /dev/vda1
    if [ "$src" = "/dev/root" ] || ! _is_blk "$src"; then
        local r; r=$(sed -n 's/.*\broot=\([^ ]*\).*/\1/p' /proc/cmdline)
        case "$r" in
            UUID=*|PARTUUID=*|LABEL=*) src=$(blkid -t "$r" -o device 2>/dev/null | head -n1) ;;
            /dev/*)                    src="$r" ;;
        esac
    fi
    [ -n "$src" ] && _is_blk "$src" || return 1
    disks=$(lsblk -nsro NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u)
    [ -n "$disks" ] || return 1
    if [ "$(wc -l <<<"$disks")" -gt 1 ]; then
        echo "MULTI:$(tr '\n' ' ' <<<"$disks")"
        return 0
    fi
    echo "/dev/$disks"
}

# Legacy heuristic (v2.2), only used when the root disk cannot be derived.
detect_disk_fallback() {
    local dev
    if [ -d /sys/block ]; then
        for dev in $(ls /sys/block | grep -E '^(sd|vd|xvd|nvme|hd)'); do
            if [ -f "/sys/block/$dev/removable" ] && [ "$(cat "/sys/block/$dev/removable")" = "0" ]; then
                echo "/dev/$dev"; return 0
            fi
        done
    fi
    dev=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^(loop|nbd|ram|zram)/ {print $1; exit}')
    [ -n "$dev" ] && echo "/dev/$dev"
}

# MAC address to match the NIC in the new system. The installed system may
# name the interface differently (eth0 vs ens3), so v2.2 matched every
# Ethernet NIC instead — giving ALL NICs the same static IP on multi-NIC
# hosts. For bridges/bonds, use the first physical member's MAC.
detect_nic_mac() {   # IFACE
    local ifc="$1" m
    if [ -e "/sys/class/net/$ifc/device" ]; then
        cat "/sys/class/net/$ifc/address"; return 0
    fi
    for m in /sys/class/net/"$ifc"/brif/* /sys/class/net/"$ifc"/lower_*; do
        [ -e "$m" ] || continue
        m="$(basename "$m")"; m="${m#lower_}"
        if [ -e "/sys/class/net/$m/device" ]; then
            cat "/sys/class/net/$m/address"; return 0
        fi
    done
    return 1
}

# Allow tests to load only the helpers above.
if [ "${OSNOVA_LIB_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# --- Help ---
show_help() {
    echo -e "${CYAN}OsNova v${VERSION} - System Deployment & Reinstallation Engine${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  bash reinstall.sh [options]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo -e "  ${YELLOW}-d [11|12|13]${NC}           Install Debian (default: 13)"
    echo -e "  ${YELLOW}-u [22|24|26]${NC}           Install Ubuntu (default: 24)"
    echo -e "  ${YELLOW}-p PASSWORD${NC}             Set root password (optional)"
    echo -e "  ${YELLOW}-port PORT, --port PORT${NC} Set SSH port (default: 22)"
    echo -e "  ${YELLOW}--dns \"IP1 IP2\"${NC}         Set DNS servers (default: 8.8.8.8 8.8.4.4)"
    echo -e "  ${YELLOW}--disk /dev/XXX${NC}         Target disk (default: the disk holding /)"
    echo -e "  ${YELLOW}-f, --force${NC}             Skip confirmation prompt"
    echo -e "  ${YELLOW}-v, --version${NC}           Show version info"
    echo -e "  ${YELLOW}-h, --help${NC}              Show this help"
    echo ""
    echo -e "${BOLD}Notes:${NC}"
    echo -e "  • If ${YELLOW}-p${NC} is not provided, a random root password will be generated."
    echo -e "  • The generated password will be shown before reboot."
    echo -e "  • Password may only contain: A-Z a-z 0-9 !@#%^*_+=.-"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  bash reinstall.sh"
    echo -e "  bash reinstall.sh -d 13"
    echo -e "  bash reinstall.sh -u"
    echo -e "  bash reinstall.sh -u 22"
    echo -e "  bash reinstall.sh -u 24 -p mypass --port 2222"
    echo -e "  bash reinstall.sh -u 24 -p mypass --port 2222 --force"
}

show_version() {
    echo -e "${CYAN}OsNova v${VERSION}${NC}"
    echo -e "GitHub: https://github.com/harryheros/osnova"
    echo -e "Copyright (C) 2026 Harry"
    echo -e "License: GPL-3.0"
}

# ==============================================================================
# ENVIRONMENT PRE-CHECKS
# ==============================================================================
check_env() {
    # 1. Root privilege check
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}"
        echo -e "${YELLOW}Hint: Use 'sudo bash reinstall.sh' or run as root user.${NC}"
        exit 1
    fi

    # 2. Architecture check (all images are amd64)
    local arch
    arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        echo -e "${RED}Error: Unsupported architecture '${arch}'.${NC}"
        echo -e "${YELLOW}OsNova only supports x86_64 (amd64) systems.${NC}"
        exit 1
    fi

    # 3. Containers (OpenVZ/LXC/Docker) share the host kernel and cannot
    #    replace their own kernel or disk — fail early with a clear reason.
    local ctype
    if ctype=$(detect_container); then
        echo -e "${RED}Error: This system runs in a container (${ctype}).${NC}"
        echo -e "${YELLOW}OsNova needs a full virtual machine (KVM, Xen, VMware, Hyper-V) or bare metal.${NC}"
        echo -e "${YELLOW}OpenVZ/LXC VPS cannot be reinstalled from inside; use the provider's panel.${NC}"
        exit 1
    fi
}

# --- Password validation (safe characters only) ---
validate_password() {
    local pass="$1"
    if [ -z "$pass" ]; then
        echo -e "${RED}Error: Password cannot be empty.${NC}"; exit 1
    fi
    # Allow: A-Z a-z 0-9 and a safe set of symbols
    # Reject anything that could break shell/heredoc/preseed: $ ` " ' \ spaces newlines ( ) { } | & ; < > ~
    if ! is_valid_password "$pass"; then
        echo -e "${RED}Error: Password contains unsupported characters.${NC}"
        echo -e "${YELLOW}Allowed characters: A-Z a-z 0-9 ! @ # % ^ * _ + = . -${NC}"
        echo -e "${YELLOW}Characters NOT allowed: \$ \` \" ' \\ spaces ( ) { } | & ; < > ~${NC}"
        exit 1
    fi
}

# --- Argument Parsing ---
DEBIAN_SET=0
UBUNTU_SET=0

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d)
            if [ "$UBUNTU_SET" -eq 1 ]; then
                echo -e "${RED}Error: Cannot use -d and -u together.${NC}"; exit 1
            fi
            DEBIAN_SET=1; OS_TYPE="debian"
            if [[ "$2" =~ ^(11|12|13)$ ]]; then RELEASE="$2"; shift 2
            elif [[ -z "$2" || "$2" == -* ]]; then RELEASE="13"; shift 1
            else
                echo -e "${RED}Error: Unsupported Debian version '$2'. (Available: 11, 12, 13)${NC}"; exit 1
            fi
            ;;
        -u)
            if [ "$DEBIAN_SET" -eq 1 ]; then
                echo -e "${RED}Error: Cannot use -d and -u together.${NC}"; exit 1
            fi
            UBUNTU_SET=1; OS_TYPE="ubuntu"
            if [[ "$2" =~ ^(22|24|26)$ ]]; then RELEASE="$2"; shift 2
            elif [[ -z "$2" || "$2" == -* ]]; then RELEASE="24"; shift 1
            else
                echo -e "${RED}Error: Unsupported Ubuntu version '$2'. (Available: 22, 24, 26)${NC}"; exit 1
            fi
            ;;
        -p)
            if [ -z "$2" ]; then
                echo -e "${RED}Error: Password cannot be empty.${NC}"; exit 1
            fi
            ROOT_PASS="$2"; shift 2
            ;;
        -port|--port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                SSH_PORT="$2"; shift 2
            else
                echo -e "${RED}Error: Invalid port number '$2' (1-65535)${NC}"; exit 1
            fi
            ;;
        --dns)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo -e "${RED}Error: DNS cannot be empty.${NC}"; exit 1
            fi
            DNS_SERVERS="$(echo "$2" | tr ',' ' ' | xargs)"
            for d in $DNS_SERVERS; do
                if ! is_ipv4 "$d" && ! is_ipv6 "$d"; then
                    echo -e "${RED}Error: Invalid DNS server '$d' (expected an IPv4 or IPv6 address).${NC}"; exit 1
                fi
            done
            shift 2
            ;;
        --disk)
            if [[ ! "$2" =~ ^/dev/[A-Za-z0-9/_.-]+$ ]]; then
                echo -e "${RED}Error: --disk expects a device path such as /dev/vda${NC}"; exit 1
            fi
            TARGET_DISK="$2"; shift 2
            ;;
        -f|--force)
            FORCE_MODE=1; shift 1
            ;;
        -v|--version)
            show_version; exit 0
            ;;
        -h|--help)
            show_help; exit 0
            ;;
        *)
            echo -e "${RED}Error: Invalid option '$1'${NC}"
            echo -e "${YELLOW}Hint: Use -d for Debian, -u for Ubuntu, -p for password, --port for SSH port.${NC}"
            exit 1
            ;;
    esac
done

if [ "$OS_TYPE" = "debian" ] && [ -z "$RELEASE" ]; then RELEASE="13"; fi
if [ "$OS_TYPE" = "ubuntu" ] && [ -z "$RELEASE" ]; then RELEASE="24"; fi

# --- Password handling (validate all input before touching the system) ---
if [ -n "$ROOT_PASS" ]; then
    validate_password "$ROOT_PASS"
else
    ROOT_PASS="$(generate_random_password)"
    PASSWORD_WAS_GENERATED=1
fi

# --- Run environment checks (root, arch, container) ---
check_env

clear
echo -e "${CYAN}"
cat << "ASCIIEOF"
   ____  _____ _   __                 
  / __ \/ ___// | / /___ _   ______ _ 
 / / / /\__ \/  |/ / __ \ | / / __ `/ 
/ /_/ /___/ / /|  / /_/ / |/ / /_/ /  
\____//____/_/ |_/\____/|___/\__,_/   
 >> System Deployment & Reinstallation Engine <<
ASCIIEOF
echo -e "${NC}"
echo -e "${CYAN}❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊${NC}"
echo -e "${GREEN}${BOLD}               OsNova Deployment Engine v${VERSION}${NC}"
echo -e "${GREEN}                     Copyright (C) 2026 Harry${NC}"
echo -e "${CYAN}❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊${NC}"

if [ "$PASSWORD_WAS_GENERATED" -eq 1 ]; then
    echo -e "\n${YELLOW}${BOLD}No root password was provided.${NC}"
    echo -e "${YELLOW}A random password has been generated for this installation:${NC}"
    echo -e "${GREEN}${BOLD}${ROOT_PASS}${NC}"
    echo -e "${RED}${BOLD}Please save this password now. It will be required after installation.${NC}"
fi

echo -e "\n${BOLD}${CYAN}Step: Pre-installing essential tools...${NC}"
export DEBIAN_FRONTEND=noninteractive

IS_CENTOS7=0
if [ -f /etc/centos-release ] && grep -q "CentOS Linux release 7" /etc/centos-release; then
    IS_CENTOS7=1
    echo -e "${YELLOW}CentOS 7 detected (EOL). Ensuring Vault 7.9.2009 repo is available...${NC}"
    cat >/etc/yum.repos.d/osnova-vault-7.9.2009.repo <<'VAULTEOF'
[osnova-vault-base]
name=OsNova Vault 7.9.2009 - Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=0

[osnova-vault-updates]
name=OsNova Vault 7.9.2009 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
enabled=1
gpgcheck=0

[osnova-vault-extras]
name=OsNova Vault 7.9.2009 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
enabled=1
gpgcheck=0
VAULTEOF
    yum clean all >/dev/null 2>&1 || true
fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl util-linux wget ca-certificates kexec-tools tar gzip cpio \
        grub2-common cloud-guest-utils e2fsprogs qemu-utils gdisk
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl util-linux wget ca-certificates kexec-tools tar gzip cpio qemu-img gdisk \
        grub2 grub2-tools cloud-utils-growpart e2fsprogs
    [ ! -f /usr/sbin/grub-probe ] && [ -f /usr/sbin/grub2-probe ] && \
        ln -sf /usr/sbin/grub2-probe /usr/sbin/grub-probe
elif command -v yum >/dev/null 2>&1; then
    if [ "$IS_CENTOS7" -eq 1 ]; then
        yum --disablerepo="*" --enablerepo="osnova-vault-*" install -y \
            curl util-linux wget ca-certificates kexec-tools tar gzip cpio \
            grub2 grub2-tools cloud-utils-growpart e2fsprogs qemu-img gdisk
    else
        yum install -y curl util-linux wget ca-certificates kexec-tools tar gzip cpio \
            grub2 grub2-tools cloud-utils-growpart e2fsprogs qemu-img gdisk
    fi
    [ ! -f /usr/sbin/grub-probe ] && [ -f /usr/sbin/grub2-probe ] && \
        ln -sf /usr/sbin/grub2-probe /usr/sbin/grub-probe
else
    echo -e "${RED}Error: Package manager not found. Please install wget manually.${NC}"; exit 1
fi

echo -e "\n${BOLD}${CYAN}Step: Detecting environment and network...${NC}"

# --- Cleanup trap ---
LOOP_DEVS=""
cleanup() {
    umount /tmp/img_root_mnt 2>/dev/null || true
    umount /tmp/efi_fix_mnt  2>/dev/null || true
    qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    for d in $LOOP_DEVS; do losetup -d "$d" 2>/dev/null || true; done
    # Large temporary images (only reached on failure/abort — the trap is
    # removed before the final disk write).
    rm -f /var/tmp/ubuntu-cloud.img /var/tmp/ubuntu-cloud.raw 2>/dev/null || true
    # Clean temporary work directory
    rm -rf /var/tmp/osnova 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP PIPE

# --- Disk Detection ---
if [ -n "$TARGET_DISK" ]; then
    REAL_DISK="$TARGET_DISK"
    if [ ! -b "$REAL_DISK" ] || [ "$(lsblk -dno TYPE "$REAL_DISK" 2>/dev/null)" != "disk" ]; then
        echo -e "${RED}Error: --disk ${REAL_DISK} is not a whole disk.${NC}"
        lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"' | sed 's/^/        /'
        exit 1
    fi
else
    REAL_DISK="$(detect_root_disk || true)"
    case "$REAL_DISK" in
        MULTI:*)
            echo -e "${RED}Error: the root filesystem spans several disks (${REAL_DISK#MULTI:}).${NC}"
            echo -e "${YELLOW}OsNova installs onto one disk. Choose it explicitly with --disk /dev/XXX.${NC}"
            exit 1
            ;;
        "")
            REAL_DISK="$(detect_disk_fallback || true)"
            if [ -z "$REAL_DISK" ]; then
                echo -e "${RED}Error: Could not determine the system disk. Use --disk /dev/XXX.${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Warning: could not trace / to a disk; guessed ${REAL_DISK}.${NC}"
            echo -e "${YELLOW}If this is wrong, answer anything but 'yes' below and rerun with --disk.${NC}"
            ;;
    esac
fi

# --- Network Detection ---
# Parse `ip route` by keyword (via/dev) rather than column position: a route
# without "via" (e.g. "default dev eth0 scope link") would otherwise yield an
# interface name as the "gateway".
ROUTE4=$(ip -4 route show default 2>/dev/null | head -n1)
INTERFACE=$(route_field "$ROUTE4" dev)
V_GATEWAY=$(route_field "$ROUTE4" via)
if [ -z "$INTERFACE" ]; then
    echo -e "${RED}Error: No IPv4 default route detected. Cannot continue.${NC}"
    echo -e "${YELLOW}Hint: verify the system has working IPv4 connectivity before running OsNova.${NC}"
    exit 1
fi

# First global address on the interface (cloud VPS often add aliases).
V_CIDR=$(ip -4 -o addr show dev "$INTERFACE" scope global 2>/dev/null | awk '{print $4; exit}')
V_IP="${V_CIDR%/*}"
V_PREFIX="${V_CIDR#*/}"

if [ -z "$V_CIDR" ] || [ -z "$V_GATEWAY" ] || ! is_ipv4 "$V_IP" || ! is_ipv4 "$V_GATEWAY"; then
    echo -e "${RED}Error: Could not determine IPv4 configuration for ${INTERFACE}.${NC}"
    echo -e "${YELLOW}Detected: IP='${V_IP}' prefix='${V_PREFIX}' gw='${V_GATEWAY}'${NC}"
    exit 1
fi

V_ONLINK4=0
gateway4_needs_onlink "$V_IP" "$V_PREFIX" "$V_GATEWAY" && V_ONLINK4=1

NIC_MAC="$(detect_nic_mac "$INTERFACE" || true)"
if [ -z "$NIC_MAC" ]; then
    echo -e "${YELLOW}Warning: ${INTERFACE} is not a physical NIC; the new system will configure every Ethernet NIC.${NC}"
fi

# IPv6 (optional). Only a stable global address (no temporary/deprecated/
# tentative SLAAC privacy addresses) and a default route on the SAME
# interface are carried over.
V_CIDR6=$(ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null \
          | grep -v -e temporary -e deprecated -e tentative | awk '{print $4; exit}')
V_IP6="${V_CIDR6%/*}"
V_PREFIX6="${V_CIDR6#*/}"
ROUTE6=$(ip -6 route show default dev "$INTERFACE" 2>/dev/null | head -n1)
V_GATEWAY6=$(route_field "$ROUTE6" via)
if [ -z "$V_CIDR6" ]; then V_IP6=""; V_PREFIX6=""; fi

# IPv6 reachability validation. Some VPS (common on budget providers) hand out
# an IPv6 address and even a default route that does NOT actually work — the
# upstream simply doesn't route IPv6. Detecting the address alone is not enough:
# if we carry a half-broken IPv6 into the install, the Debian netboot installer
# tries the AAAA record of deb.debian.org when fetching udebs, times out, and
# stalls at a random "Retrieving *-udeb" step. We therefore probe actual
# connectivity and DISABLE IPv6 entirely if it fails — degrading cleanly to
# IPv4-only. Machines with working IPv6 keep full dual-stack; IPv4-only machines
# are unaffected.
if [ -n "$V_IP6" ] && [ -n "$V_GATEWAY6" ]; then
    # Only trust the probe if a v6-capable ping tool actually exists; otherwise
    # a missing tool would falsely "fail" the test and wrongly disable working
    # IPv6. If no tool is available, keep the old behavior (assume usable).
    if command -v ping6 >/dev/null 2>&1 || command -v ping >/dev/null 2>&1; then
        # Try gateway first (fast, local), then a public anycast as a second chance.
        # A link-local gateway (fe80::/10) must be pinged with an interface scope.
        GW6_PING="$V_GATEWAY6"
        case "${V_GATEWAY6,,}" in fe80:*) GW6_PING="${V_GATEWAY6}%${INTERFACE}" ;; esac
        if ping6 -c1 -W2 "$GW6_PING" >/dev/null 2>&1 \
           || ping -6 -c1 -W2 "$GW6_PING" >/dev/null 2>&1 \
           || ping6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1 \
           || ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1; then
            : # IPv6 works — keep it
        else
            echo -e "${YELLOW}IPv6 address detected but not reachable — disabling IPv6 (IPv4-only install).${NC}"
            V_IP6=""; V_PREFIX6=""; V_GATEWAY6=""
            IPV6_USABLE=0
        fi
    fi
fi

V_ONLINK6=0
if [ -n "$V_IP6" ] && [ -n "$V_GATEWAY6" ]; then
    gateway6_needs_onlink "$V_IP6" "$V_PREFIX6" "$V_GATEWAY6" && V_ONLINK6=1
fi

# IPv6 resolvers are useless (and slow every lookup down) when the new system
# will have no working IPv6 — keep only IPv4 servers in that case.
if [ "$IPV6_USABLE" -eq 0 ] || [ -z "$V_IP6" ] || [ -z "$V_GATEWAY6" ]; then
    DNS_V4_ONLY=""
    for d in $DNS_SERVERS; do is_ipv4 "$d" && DNS_V4_ONLY="${DNS_V4_ONLY:+$DNS_V4_ONLY }$d"; done
    if [ "$DNS_V4_ONLY" != "$DNS_SERVERS" ]; then
        [ -z "$DNS_V4_ONLY" ] && DNS_V4_ONLY="8.8.8.8 8.8.4.4"
        echo -e "${YELLOW}No working IPv6 on this host — using IPv4 DNS only: ${DNS_V4_ONLY}${NC}"
        DNS_SERVERS="$DNS_V4_ONLY"
    fi
fi

V_NETMASK=$(prefix_to_mask "$V_PREFIX")

# --- Resolve display names ---
if [ "$OS_TYPE" = "debian" ]; then
    case "$RELEASE" in
        "11") REL_NAME="bullseye" ;;
        "12") REL_NAME="bookworm" ;;
        *)    REL_NAME="trixie"   ;;
    esac
    DISPLAY_NAME="Debian ${RELEASE} (${REL_NAME})"
else
    case "$RELEASE" in
        "22") REL_NAME="jammy";    FULL_VER="22.04" ;;
        "26") REL_NAME="resolute"; FULL_VER="26.04" ;;
        *)    REL_NAME="noble";    FULL_VER="24.04" ;;
    esac
    DISPLAY_NAME="Ubuntu ${FULL_VER} (${REL_NAME})"
fi

echo -e "      Target OS : ${YELLOW}${DISPLAY_NAME}${NC}"
echo -e "      Root Disk : ${YELLOW}${REAL_DISK}${NC}"
echo -e "      IP Config : ${YELLOW}${V_IP} / ${V_NETMASK} via ${V_GATEWAY}${NC}$([ "$V_ONLINK4" -eq 1 ] && echo " (on-link)")"
echo -e "      Interface : ${YELLOW}${INTERFACE}${NC}${NIC_MAC:+ (MAC ${NIC_MAC})}"
[ -n "$V_IP6" ] && echo -e "      IPv6      : ${YELLOW}${V_IP6}/${V_PREFIX6}${V_GATEWAY6:+ via ${V_GATEWAY6}}${NC}"

# ==============================================================================
# PRE-FLIGHT CHECKS (before anything is modified)
# ==============================================================================
PREFLIGHT_FAIL=0
avail_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

MEM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$OS_TYPE" = "debian" ] && [ "${MEM_MB:-0}" -lt 512 ]; then
    echo -e "${YELLOW}Warning: only ${MEM_MB} MB RAM. Below ~512 MB the Debian installer runs in"
    echo -e "         low-memory mode and may stop at prompts. Ubuntu (-u) avoids the installer.${NC}"
fi

if [ "$OS_TYPE" = "debian" ]; then
    BOOT_FREE=$(avail_mb /boot)
    if [ -n "$BOOT_FREE" ] && [ "$BOOT_FREE" -lt 150 ]; then
        echo -e "${RED}Error: /boot has only ${BOOT_FREE} MB free; the installer needs about 150 MB.${NC}"
        echo -e "${YELLOW}Remove old kernels (e.g. apt autoremove / package-cleanup --oldkernels) and retry.${NC}"
        PREFLIGHT_FAIL=1
    fi
    if [ "$RELEASE" = "11" ]; then
        echo -e "${YELLOW}Note: Debian 11 reached end of life on 2026-08-31 (no more security updates).${NC}"
    fi
else
    TMP_FREE=$(avail_mb /var/tmp)
    if [ -n "$TMP_FREE" ] && [ "$TMP_FREE" -lt 1500 ]; then
        echo -e "${RED}Error: /var/tmp has only ${TMP_FREE} MB free; the Ubuntu image needs at least 1.5 GB.${NC}"
        PREFLIGHT_FAIL=1
    fi
fi

DISK_BYTES=$(lsblk -bdno SIZE "$REAL_DISK" 2>/dev/null || echo 0)
if [ "${DISK_BYTES:-0}" -gt 0 ] && [ "$DISK_BYTES" -lt $((4 * 1024 * 1024 * 1024)) ]; then
    echo -e "${RED}Error: ${REAL_DISK} is smaller than 4 GB.${NC}"
    PREFLIGHT_FAIL=1
fi

[ "$PREFLIGHT_FAIL" -eq 1 ] && exit 1

echo ""
echo -e "      Disks on this system (target marked):"
lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | awk -v t="$(basename "$REAL_DISK")" \
    '$3 == "disk" { printf "        %s %s\n", ($1 == t ? "=>" : "  "), $0 }'

# ==============================================================================
# CONFIRMATION PROMPT (skip with --force / -f)
# ==============================================================================
if [ "$FORCE_MODE" -eq 0 ]; then
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will ERASE ALL DATA on ${REAL_DISK} and reinstall ${DISPLAY_NAME}.${NC}"
    echo -e "${RED}${BOLD}This action is irreversible.${NC}"
    echo ""
    echo -ne "${YELLOW}Type 'yes' to continue, or anything else to abort: ${NC}"
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${CYAN}Aborted. No changes were made.${NC}"
        exit 0
    fi
fi

WORKDIR="/var/tmp/osnova"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"

# ==============================================================================
# DEBIAN INSTALLATION PATH
# ==============================================================================
install_debian() {
    echo -e "\n${BOLD}${CYAN}Step: Fetching Debian network installer...${NC}"

    # Releases past end of life are moved from deb.debian.org to
    # archive.debian.org. Probe the regular mirror first, fall back to the
    # archive (Debian 11 reached EOL on 2026-08-31 and will be moved).
    MIRROR_HOST="deb.debian.org"
    MIRROR="https://${MIRROR_HOST}/debian/dists/${REL_NAME}/main/installer-amd64/current/images/netboot/"
    if ! wget -q --spider --tries=2 --timeout=20 "${MIRROR}netboot.tar.gz"; then
        ARCHIVE_MIRROR="https://archive.debian.org/debian/dists/${REL_NAME}/main/installer-amd64/current/images/netboot/"
        if wget -q --spider --tries=2 --timeout=20 "${ARCHIVE_MIRROR}netboot.tar.gz"; then
            echo -e "${YELLOW}${REL_NAME} is no longer on deb.debian.org — using archive.debian.org.${NC}"
            MIRROR_HOST="archive.debian.org"
            MIRROR="$ARCHIVE_MIRROR"
        fi
    fi
    # --tries=3 --timeout=30: transient hiccups (mirror DNS jitter, brief TLS
    # reset) shouldn't force the operator to restart the entire reinstall.
    wget --tries=3 --timeout=30 -O "${WORKDIR}/netboot.tar.gz" "${MIRROR}netboot.tar.gz"

    # --- systemd-networkd configuration for the installed system ---
    # Match the NIC by MAC address: the new system may name it differently
    # (eth0 vs ens3), and matching every Ethernet NIC (v2.2) gave all NICs
    # the same static IP on multi-NIC hosts.
    if [ -n "$NIC_MAC" ]; then
        NETWORKD_MATCH="MACAddress=${NIC_MAC}"
    else
        NETWORKD_MATCH="Type=ether"
    fi

    NETWORKD_ROUTE4="
[Route]
Destination=0.0.0.0/0
Gateway=${V_GATEWAY}"
    [ "$V_ONLINK4" -eq 1 ] && NETWORKD_ROUTE4="${NETWORKD_ROUTE4}
GatewayOnLink=yes"

    NETWORKD_IPV6_BLOCK=""
    NETWORKD_IPV6_NETWORK=""
    if [ "$IPV6_USABLE" -eq 0 ]; then
        # IPv6 was found broken: keep it off in the installed system too
        # (v2.2 only disabled it for the installer; networkd still accepted
        # router advertisements and picked the broken IPv6 back up).
        NETWORKD_IPV6_NETWORK="IPv6AcceptRA=no
LinkLocalAddressing=ipv4"
    elif [ -n "$V_IP6" ] && [ -n "$V_PREFIX6" ]; then
        NETWORKD_IPV6_BLOCK="
[Address]
Address=${V_IP6}/${V_PREFIX6}"
        if [ -n "$V_GATEWAY6" ]; then
            NETWORKD_IPV6_BLOCK="${NETWORKD_IPV6_BLOCK}

[Route]
Destination=::/0
Gateway=${V_GATEWAY6}"
            [ "$V_ONLINK6" -eq 1 ] && NETWORKD_IPV6_BLOCK="${NETWORKD_IPV6_BLOCK}
GatewayOnLink=yes"
        fi
    fi

    IPV6_SYSCTL=""
    if [ "$IPV6_USABLE" -eq 0 ]; then
        IPV6_SYSCTL="net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1"
    fi

    cat > "${WORKDIR}/post-install.sh" <<POSTINSTALL
#!/bin/sh
set -e

# --- SSH config ---
# Primary mechanism: a sshd_config.d drop-in (Debian 12+/Ubuntu read these via
# the Include at the top of sshd_config, and first-match-wins means our values
# take effect). chmod 644 is REQUIRED — sshd refuses to load a drop-in that is
# group/other-writable and silently ignores it.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-osnova.conf <<'SSHEOF'
PermitRootLogin yes
PasswordAuthentication yes
Port ${SSH_PORT}
SSHEOF
chmod 644 /etc/ssh/sshd_config.d/99-osnova.conf

# Fallback: also patch the main config for systems without an Include line.
# Guarded with a file-existence test and || true so that a missing or unusual
# main config can never abort this script under set -e (which would otherwise
# skip the BBR/network steps below).
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config || true
    if grep -qE '^#?\s*Port\s' /etc/ssh/sshd_config; then
        sed -i 's/^#\?\s*Port\s.*/Port ${SSH_PORT}/g' /etc/ssh/sshd_config || true
    else
        echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
    fi
fi

# Debian ships ssh as socket-activated (ssh.socket), whose ListenStream=22
# OVERRIDES the Port in sshd_config — so a custom port silently fails to take
# effect. Disable the socket unit and fall back to the classic ssh.service so
# the configured Port is the one that listens. Guarded for chroot (no running
# systemd) and for systems that don't use the socket.
if [ -e /lib/systemd/system/ssh.socket ] || [ -e /etc/systemd/system/ssh.socket ]; then
    systemctl disable ssh.socket 2>/dev/null || true
    rm -f /etc/systemd/system/ssh.service.requires/ssh.socket 2>/dev/null || true
fi
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true

# --- BBR ---
cat > /etc/sysctl.d/99-osnova-bbr.conf <<'BBREOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF

# --- Network: systemd-networkd, NIC matched by MAC address ---
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-static.network <<EOF
[Match]
${NETWORKD_MATCH}

[Network]
Address=${V_IP}/${V_PREFIX}
$(echo "${DNS_SERVERS}" | tr ' ' '\n' | sed 's/^/DNS=/')
${NETWORKD_IPV6_NETWORK}
${NETWORKD_ROUTE4}
${NETWORKD_IPV6_BLOCK}
EOF

if [ -n "${IPV6_SYSCTL}" ]; then
    printf '%s\n' "${IPV6_SYSCTL}" > /etc/sysctl.d/99-osnova-ipv6.conf
fi

# Enable systemd-networkd, disable legacy networking
# In the d-i chroot there is no running systemd/D-Bus, so these can return
# non-zero even when the symlink is created correctly. Guard with || true so
# set -e does not abort the script (which would skip the steps below).
systemctl enable systemd-networkd 2>/dev/null || true
systemctl disable networking 2>/dev/null || true

# Disable /etc/network/interfaces to avoid conflict
printf '# Managed by systemd-networkd\n# See /etc/systemd/network/\n' > /etc/network/interfaces

# Ensure all writes are flushed to disk before reboot
sync
POSTINSTALL
    chmod +x "${WORKDIR}/post-install.sh"

    cat > "${WORKDIR}/preseed.cfg" <<'PRESEEDEOF'
d-i debconf/priority string critical
d-i auto-install/enable boolean true
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i hw-detect/load_firmware boolean false
PRESEEDEOF

    # Append network and disk config (these contain variables, use expanding heredoc)
    # NOTE: netcfg/get_nameservers must be a SINGLE address for d-i — a
    # space-separated list breaks udeb-stage DNS resolution (the installer
    # uses it verbatim as one token). Use the first DNS for the installer;
    # the full DNS_SERVERS list is still written into the final system by
    # post-install.sh. The mirror/* block is REQUIRED: without it the
    # installer stalls at "Loading additional components / Retrieving *.udeb"
    # because it has no mirror host to fetch udebs from.
    # The installer needs an IPv4 resolver (IPv6 may be disabled for it).
    FIRST_DNS=""
    for d in $DNS_SERVERS; do is_ipv4 "$d" && { FIRST_DNS="$d"; break; }; done
    [ -z "$FIRST_DNS" ] && FIRST_DNS="8.8.8.8"
    cat >> "${WORKDIR}/preseed.cfg" <<EOF
d-i netcfg/get_ipaddress string ${V_IP}
d-i netcfg/get_netmask string ${V_NETMASK}
d-i netcfg/get_gateway string ${V_GATEWAY}
d-i netcfg/get_nameservers string ${FIRST_DNS}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string localdomain
d-i netcfg/hostname string debian

d-i mirror/country string manual
d-i mirror/protocol string http
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string ${REL_NAME}
d-i apt-setup/use_mirror boolean true
EOF
    if [ "$MIRROR_HOST" = "archive.debian.org" ]; then
        cat >> "${WORKDIR}/preseed.cfg" <<'EOF'
# Archived release: the security/updates services are not available the
# same way as on live mirrors, and archived Release files are expired.
d-i apt-setup/services-select multiselect
d-i apt-setup/check_valid_until boolean false
EOF
    fi
    cat >> "${WORKDIR}/preseed.cfg" <<EOF

tasksel tasksel/first multiselect standard, ssh-server
# Belt-and-suspenders: explicitly include openssh-server. The ssh-server
# tasksel entry can be skipped on some mirrors/releases, which would leave the
# box with no sshd at all — sshd_config edits then apply to nothing and the
# host is unreachable. pkgsel/include guarantees the package is installed.
d-i pkgsel/include string openssh-server
d-i pkgsel/upgrade select none

# Wipe any pre-existing LVM/MD/partition signatures BEFORE partman scans the
# disk. On VPS that were previously provisioned with LVM or software RAID,
# partman otherwise stops to ask about active volume groups / md arrays —
# a prompt that priority=critical cannot auto-answer, causing a silent hang.
d-i partman/early_command string \
    disk="${REAL_DISK}"; \
    vgchange -an 2>/dev/null || true; \
    for v in \$(pvs --noheadings -o pv_name 2>/dev/null | grep "\$disk"); do pvremove -ff -y "\$v" 2>/dev/null || true; done; \
    mdadm --stop --scan 2>/dev/null || true; \
    wipefs -a "\$disk" 2>/dev/null || true

d-i partman-auto/disk string ${REAL_DISK}
d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${REAL_DISK}

d-i passwd/make-user boolean false
EOF

    # Append password lines using printf to avoid any shell expansion issues
    printf 'd-i passwd/root-password password %s\n' "${ROOT_PASS}" >> "${WORKDIR}/preseed.cfg"
    printf 'd-i passwd/root-password-again password %s\n' "${ROOT_PASS}" >> "${WORKDIR}/preseed.cfg"

    cat >> "${WORKDIR}/preseed.cfg" <<'PRESEEDTAILEOF'
d-i finish-install/reboot_in_progress note

# late_command runs in the d-i environment (not the target). We search a few
# known locations for post-install.sh because where it survives depends on the
# d-i build: initrd root (/), the preseed dir, or /var/lib/preseed. Chaining
# with && (not ;) so a copy/run failure is visible in /var/log/syslog rather
# than silently rebooting into a half-configured network. All output is logged
# to the target so it can be inspected post-boot if SSH still fails.
d-i preseed/late_command string \
    mkdir -p /target/tmp; \
    cp /post-install.sh /target/tmp/post-install.sh && \
    in-target chmod +x /tmp/post-install.sh && \
    in-target /tmp/post-install.sh; \
    sync; sleep 3
PRESEEDTAILEOF

    cd "$WORKDIR" && tar -xzf netboot.tar.gz
    mkdir -p initrd_work && cd initrd_work
    gzip -dc "../debian-installer/amd64/initrd.gz" | cpio -idmu >/dev/null 2>&1
    cp "${WORKDIR}/preseed.cfg" ./preseed.cfg
    # Place post-install.sh in several locations the late_command searches,
    # so it survives regardless of how this d-i build lays out its root.
    cp "${WORKDIR}/post-install.sh" ./post-install.sh
    mkdir -p ./preseed && cp "${WORKDIR}/post-install.sh" ./preseed/post-install.sh
    chmod +x ./post-install.sh ./preseed/post-install.sh

    rm -f /boot/vmlinuz-*osnova /boot/initrd-*osnova.gz 2>/dev/null
    find . | cpio -H newc -o 2>/dev/null | gzip -1 > /boot/initrd-debian${RELEASE}-osnova.gz
    cp "${WORKDIR}/debian-installer/amd64/linux" /boot/vmlinuz-debian${RELEASE}-osnova

    KERNEL_PATH="/boot/vmlinuz-debian${RELEASE}-osnova"
    INITRD_PATH="/boot/initrd-debian${RELEASE}-osnova.gz"
    NET_APPEND="netcfg/disable_autoconfig=true netcfg/get_ipaddress=${V_IP} netcfg/get_netmask=${V_NETMASK} netcfg/get_gateway=${V_GATEWAY} netcfg/get_nameservers=${FIRST_DNS} netcfg/confirm_static=true netcfg/get_hostname=debian netcfg/get_domain=localdomain"
    MIRROR_APPEND="mirror/http/hostname=${MIRROR_HOST} mirror/http/directory=/debian mirror/suite=${REL_NAME}"
    # If IPv6 was found unusable (address present but unreachable), disable it at
    # the kernel level for the installer. Otherwise d-i resolves deb.debian.org's
    # AAAA record, tries IPv6 to fetch udebs, times out, and stalls at a random
    # "Retrieving *-udeb" step. ipv6.disable=1 forces the whole udeb fetch over
    # IPv4. Working-IPv6 and IPv4-only machines never reach this branch.
    IPV6_APPEND=""
    if [ "$IPV6_USABLE" -eq 0 ]; then
        IPV6_APPEND="ipv6.disable=1"
    fi
    KERNEL_APPEND="auto=true priority=critical file=/preseed.cfg locale=en_US.UTF-8 keymap=us hostname=debian domain=localdomain ${NET_APPEND} ${MIRROR_APPEND} ${IPV6_APPEND} vga=788 --- quiet"
    GRUB_TITLE="OsNova-Debian${RELEASE}"
    UBUNTU_CLOUD=0
}

# ==============================================================================
# UBUNTU INSTALLATION PATH
# NBD mount → chroot config → EFI fix → disconnect → convert → reboot
# ==============================================================================
install_ubuntu() {
    echo -e "\n${BOLD}${CYAN}Step: Installing Ubuntu via cloud image...${NC}"
    IMG_URL="https://cloud-images.ubuntu.com/releases/${REL_NAME}/release/ubuntu-${FULL_VER}-server-cloudimg-amd64.img"
    IMG_PATH="/var/tmp/ubuntu-cloud.img"
    RAW_PATH="/var/tmp/ubuntu-cloud.raw"
    # Remove stale images from any previous run (a resumed download from a
    # different release URL would produce a spliced file).
    rm -f "${IMG_PATH}" "${RAW_PATH}"
    echo -e "${CYAN}Downloading Ubuntu ${FULL_VER} cloud image...${NC}"
    wget --tries=3 --timeout=60 --show-progress -O "${IMG_PATH}" "${IMG_URL}"

    # 1. Checksum against Ubuntu's published SHA256SUMS (same directory).
    echo -e "${CYAN}Verifying image checksum...${NC}"
    local sums expected actual
    sums="$(wget -q -O - "${IMG_URL%/*}/SHA256SUMS" 2>/dev/null || true)"
    expected="$(awk -v f="$(basename "$IMG_URL")" '$2 == f || $2 == "*" f {print $1; exit}' <<<"$sums")"
    if [ -n "$expected" ]; then
        actual="$(sha256sum "${IMG_PATH}" | awk '{print $1}')"
        if [ "$actual" != "$expected" ]; then
            echo -e "${RED}Error: checksum mismatch — the download is corrupted or incomplete.${NC}"
            rm -f "${IMG_PATH}"; exit 1
        fi
        echo -e "${GREEN}Checksum OK (SHA256SUMS).${NC}"
    else
        echo -e "${YELLOW}Warning: could not fetch SHA256SUMS; falling back to a structural check only.${NC}"
    fi

    # 2. Structural check: must be a consistent qcow2 file.
    if ! qemu-img info "${IMG_PATH}" 2>/dev/null | grep -q 'file format: qcow2'; then
        echo -e "${RED}Error: Downloaded file is not a qcow2 image.${NC}"
        echo -e "${YELLOW}Most likely an incomplete download or an HTML error page from the mirror.${NC}"
        rm -f "${IMG_PATH}"; exit 1
    fi
    if ! qemu-img check "${IMG_PATH}" >/dev/null 2>&1; then
        echo -e "${RED}Error: Downloaded image failed integrity check.${NC}"
        rm -f "${IMG_PATH}"; exit 1
    fi

    # 3. The image must fit on the target disk.
    local vsize disk_bytes
    vsize="$(qemu-img info "${IMG_PATH}" | sed -n 's/^virtual size:.*(\([0-9]*\) bytes).*/\1/p')"
    disk_bytes="$(lsblk -bdno SIZE "${REAL_DISK}")"
    if [ -n "$vsize" ] && [ "$disk_bytes" -lt "$vsize" ]; then
        echo -e "${RED}Error: ${REAL_DISK} ($((disk_bytes / 1048576)) MB) is smaller than the image ($((vsize / 1048576)) MB).${NC}"
        exit 1
    fi

    # 4. Open the image: NBD if the kernel has it, otherwise a raw copy on
    #    loop devices (Debian's "cloud" kernel and some provider kernels ship
    #    without the nbd module, and RHEL's qemu-img package has no qemu-nbd;
    #    v2.2 aborted in both cases).
    if command -v qemu-nbd >/dev/null 2>&1 && modprobe nbd max_part=16 2>/dev/null && [ -b /dev/nbd0 ]; then
        IMG_MODE="nbd"
        echo -e "${CYAN}Mounting image via NBD...${NC}"
        sleep 1
        qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
        sleep 1
        qemu-nbd --connect=/dev/nbd0 "${IMG_PATH}"
        sleep 2
        IMG_ROOT=$(lsblk -lnpb -o NAME,FSTYPE,SIZE /dev/nbd0 2>/dev/null | awk '$2=="ext4"' | sort -nk3 | tail -n1 | awk '{print $1}')
        IMG_EFI=$(lsblk -lnp -o NAME,FSTYPE /dev/nbd0 2>/dev/null | awk '$2=="vfat" {print $1; exit}')
    else
        IMG_MODE="loop"
        local tmp_free_mb need_mb
        tmp_free_mb=$(df -Pm /var/tmp | awk 'NR==2 {print $4}')
        need_mb=$(( ${vsize:-4294967296} / 1048576 + 200 ))
        if [ "$tmp_free_mb" -lt "$need_mb" ]; then
            echo -e "${RED}Error: the nbd kernel module is unavailable and /var/tmp needs ${need_mb} MB free for a raw copy (has ${tmp_free_mb} MB).${NC}"
            exit 1
        fi
        echo -e "${CYAN}nbd unavailable — converting to raw and using loop devices...${NC}"
        qemu-img convert -f qcow2 -O raw "${IMG_PATH}" "${RAW_PATH}"
        rm -f "${IMG_PATH}"
        # Map partitions by offset from the partition table (no reliance on
        # udev creating partition nodes).
        local nr start sectors fstype dev best_size=0
        while read -r nr start sectors; do
            fstype=$(blkid -p -O $((start * 512)) -o export "${RAW_PATH}" 2>/dev/null | sed -n 's/^TYPE=//p')
            case "$fstype" in
                ext4|vfat)
                    dev=$(losetup -f --show --offset $((start * 512)) --sizelimit $((sectors * 512)) "${RAW_PATH}")
                    LOOP_DEVS="${LOOP_DEVS} ${dev}"
                    if [ "$fstype" = "ext4" ] && [ "$sectors" -gt "$best_size" ]; then
                        IMG_ROOT="$dev"; best_size="$sectors"
                    elif [ "$fstype" = "vfat" ] && [ -z "$IMG_EFI" ]; then
                        IMG_EFI="$dev"
                    fi
                    ;;
            esac
        done < <(partx -g -o NR,START,SECTORS "${RAW_PATH}")
    fi
    echo -e "${CYAN}Root: ${IMG_ROOT} | EFI: ${IMG_EFI:-none} (${IMG_MODE})${NC}"
    if [ -z "$IMG_ROOT" ]; then
        echo -e "${RED}Error: could not find the root filesystem inside the image.${NC}"
        exit 1
    fi

    ROOT_MNT="/tmp/img_root_mnt"
    mkdir -p "${ROOT_MNT}"
    mount -t ext4 "${IMG_ROOT}" "${ROOT_MNT}"

    # 5. Root password (chpasswd inside the image; validated charset).
    echo "root:${ROOT_PASS}" | chroot "${ROOT_MNT}" chpasswd

    # 6. SSH — patch main config + write .d override. Removing the image's
    #    own drop-ins drops 60-cloudimg-settings.conf (PasswordAuthentication no).
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${ROOT_MNT}/etc/ssh/sshd_config"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${ROOT_MNT}/etc/ssh/sshd_config"
    if grep -qE '^#?\s*Port\s' "${ROOT_MNT}/etc/ssh/sshd_config"; then
        sed -i "s/^#\?\s*Port\s.*/Port ${SSH_PORT}/" "${ROOT_MNT}/etc/ssh/sshd_config"
    else
        echo "Port ${SSH_PORT}" >> "${ROOT_MNT}/etc/ssh/sshd_config"
    fi
    mkdir -p "${ROOT_MNT}/etc/ssh/sshd_config.d"
    rm -f "${ROOT_MNT}/etc/ssh/sshd_config.d/"*
    cat > "${ROOT_MNT}/etc/ssh/sshd_config.d/99-osnova.conf" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
Port ${SSH_PORT}
EOF
    chmod 644 "${ROOT_MNT}/etc/ssh/sshd_config.d/99-osnova.conf"

    # 7. BBR (+ IPv6 off if it was found broken)
    cat > "${ROOT_MNT}/etc/sysctl.d/99-osnova-bbr.conf" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    if [ "$IPV6_USABLE" -eq 0 ]; then
        cat > "${ROOT_MNT}/etc/sysctl.d/99-osnova-ipv6.conf" <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    fi

    # 8. Static netplan. netplan's `match:` only accepts name / macaddress /
    #    driver; v2.2 used `type: ethernet`, which netplan rejects as an
    #    unknown key — leaving the installed system without any network.
    rm -f "${ROOT_MNT}/etc/netplan/"*.yaml
    local match route4 route6="" addrs v6opts=""
    if [ -n "$NIC_MAC" ]; then
        match="macaddress: \"${NIC_MAC}\""
    else
        match="name: \"e*\""
    fi
    addrs="\"${V_IP}/${V_PREFIX}\""
    # Note: build optional parts with if/else — under `set -e`, an assignment
    # like x="$([ cond ] && echo y)" aborts the script when cond is false.
    local onlink4="" onlink6=""
    [ "$V_ONLINK4" -eq 1 ] && onlink4=", on-link: true"
    [ "$V_ONLINK6" -eq 1 ] && onlink6=", on-link: true"
    route4="{to: default, via: \"${V_GATEWAY}\"${onlink4}}"
    if [ "$IPV6_USABLE" -eq 0 ]; then
        v6opts="
      accept-ra: false
      link-local: [ ipv4 ]"
    elif [ -n "$V_IP6" ] && [ -n "$V_PREFIX6" ]; then
        addrs="${addrs}, \"${V_IP6}/${V_PREFIX6}\""
        if [ -n "$V_GATEWAY6" ]; then
            route6=", {to: \"::/0\", via: \"${V_GATEWAY6}\"${onlink6}}"
        fi
    fi
    local dns_list="" d
    for d in $DNS_SERVERS; do dns_list="${dns_list:+${dns_list}, }\"${d}\""; done

    cat > "${ROOT_MNT}/etc/netplan/99-static-ip.yaml" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    primary:
      match:
        ${match}
      dhcp4: false
      dhcp6: false${v6opts}
      addresses: [${addrs}]
      routes: [${route4}${route6}]
      nameservers: {addresses: [${dns_list}]}
EOF
    chmod 600 "${ROOT_MNT}/etc/netplan/99-static-ip.yaml"

    # 9. Disable cloud-init network generation
    mkdir -p "${ROOT_MNT}/etc/cloud/cloud.cfg.d"
    echo "network: {config: disabled}" > "${ROOT_MNT}/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

    # 10. Cloud-init seed — grow the root partition to the full disk
    REAL_PART="$(part_dev "${REAL_DISK}" 1)"
    mkdir -p "${ROOT_MNT}/var/lib/cloud/seed/nocloud"
    cat > "${ROOT_MNT}/var/lib/cloud/seed/nocloud/meta-data" <<EOF
instance-id: i-$(date +%s)
local-hostname: ubuntu
EOF
    cat > "${ROOT_MNT}/var/lib/cloud/seed/nocloud/user-data" <<EOF
#cloud-config
runcmd:
  - growpart ${REAL_DISK} 1 || true
  - resize2fs ${REAL_PART} || true
EOF

    sync
    umount "${ROOT_MNT}"
    echo -e "${GREEN}Root filesystem configured!${NC}"

    # 11. EFI fallback path (firmware without an NVRAM entry boots EFI/BOOT)
    if [ -n "$IMG_EFI" ] && [ -b "$IMG_EFI" ]; then
        EFI_MNT="/tmp/efi_fix_mnt"
        mkdir -p "${EFI_MNT}"
        if mount -t vfat "${IMG_EFI}" "${EFI_MNT}" 2>/dev/null; then
            mkdir -p "${EFI_MNT}/EFI/BOOT"
            if [ -f "${EFI_MNT}/EFI/ubuntu/shimx64.efi" ]; then
                cp "${EFI_MNT}/EFI/ubuntu/shimx64.efi" "${EFI_MNT}/EFI/BOOT/BOOTX64.EFI"
                cp "${EFI_MNT}/EFI/ubuntu/grubx64.efi" "${EFI_MNT}/EFI/BOOT/grubx64.efi" 2>/dev/null || true
                echo -e "${GREEN}EFI/BOOT/BOOTX64.EFI written!${NC}"
            fi
            sync
            umount "${EFI_MNT}"
        fi
    fi

    # Release the image; the destructive write happens at the very end.
    if [ "$IMG_MODE" = "nbd" ]; then
        qemu-nbd --disconnect /dev/nbd0
        WRITE_SRC="${IMG_PATH}"; WRITE_FMT="qcow2"
    else
        for d in $LOOP_DEVS; do losetup -d "$d" 2>/dev/null || true; done
        LOOP_DEVS=""
        WRITE_SRC="${RAW_PATH}"; WRITE_FMT="raw"
    fi
    sync
    GRUB_TITLE=""
    UBUNTU_CLOUD=1
}

# Write the prepared image over the live system disk and reboot at once.
# The running filesystem is first remounted read-only (sysrq "u") so it can
# no longer flush logs/metadata on top of the new image — in v2.2 the image
# was written first and the old system kept running for the countdown.
ubuntu_write_and_reboot() {
    echo -e "\n${BOLD}${CYAN}Step: Writing Ubuntu to ${REAL_DISK} — do not interrupt...${NC}"
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    sync
    if [ -w /proc/sysrq-trigger ]; then
        echo u > /proc/sysrq-trigger
        sleep 3
    else
        mount -o remount,ro / 2>/dev/null || \
            echo -e "${YELLOW}Warning: could not remount / read-only; continuing.${NC}"
    fi
    qemu-img convert -f "${WRITE_FMT}" -O raw -p "${WRITE_SRC}" "${REAL_DISK}"
    blockdev --flushbufs "${REAL_DISK}" 2>/dev/null || true
    # Move the GPT backup header to the real end of the (larger) disk.
    sgdisk -e "${REAL_DISK}" >/dev/null 2>&1 || true
    blockdev --flushbufs "${REAL_DISK}" 2>/dev/null || true
    echo -e "${GREEN}Ubuntu written to disk. Rebooting now.${NC}"
    echo b > /proc/sysrq-trigger 2>/dev/null || true
    reboot -f -n 2>/dev/null || true
    systemctl reboot --force --force 2>/dev/null || true
    python3 -c "import ctypes; ctypes.CDLL('libc.so.6').reboot(0x1234567)" 2>/dev/null || true
}

# --- Run installer ---
if [ "$OS_TYPE" = "debian" ]; then
    install_debian
else
    install_ubuntu
fi

# ==============================================================================
# GRUB CONFIGURATION (Debian only)
# ==============================================================================
if [ "$OS_TYPE" = "debian" ]; then
    echo -e "\n${BOLD}${CYAN}Step: Patching GRUB bootloader (Debian)...${NC}"

    BOOT_UUID=$(/usr/sbin/grub-probe --target=fs_uuid /boot 2>/dev/null || grub-probe --target=fs_uuid /boot)
    KERN_BN="$(basename "${KERNEL_PATH}")"
    INIT_BN="$(basename "${INITRD_PATH}")"
    cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${GRUB_TITLE}' {
    load_video
    insmod gzio
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod xfs
    insmod btrfs
    insmod lvm
    insmod mdraid1x
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    if [ -f /boot/${KERN_BN} ]; then
        linux /boot/${KERN_BN} ${KERNEL_APPEND}
        initrd /boot/${INIT_BN}
    else
        linux /${KERN_BN} ${KERNEL_APPEND}
        initrd /${INIT_BN}
    fi
}
EOF
    chmod +x /etc/grub.d/40_custom

    # Selecting the default by menuentry TITLE only works when the entry is at
    # the top level. If GRUB builds a submenu (default on many distros), named
    # entries get nested and "GRUB_DEFAULT=title" silently fails — the box
    # boots the OLD kernel and the reinstall never starts. The canonical fix is
    # GRUB_DEFAULT=saved + grub-set-default, which resolves the title against
    # grubenv and works regardless of nesting. Also force top-level for safety.
    sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
    echo "GRUB_DEFAULT=saved" >> /etc/default/grub
    sed -i '/^GRUB_DISABLE_SUBMENU=/d' /etc/default/grub
    echo "GRUB_DISABLE_SUBMENU=y" >> /etc/default/grub
    sed -i '/^GRUB_TIMEOUT=/d' /etc/default/grub
    echo "GRUB_TIMEOUT=5" >> /etc/default/grub
    sed -i '/^GRUB_TIMEOUT_STYLE=/d' /etc/default/grub
    echo "GRUB_TIMEOUT_STYLE=menu" >> /etc/default/grub
    # Idempotent: remove existing line before appending
    sed -i '/^GRUB_DISABLE_OS_PROBER=/d' /etc/default/grub
    echo "GRUB_DISABLE_OS_PROBER=true" >> /etc/default/grub
    # Regenerate the config GRUB actually reads. RHEL-family systems use
    # /boot/grub2/grub.cfg; v2.2 wrote /boot/grub/grub.cfg there, so the
    # installer entry never appeared and the host rebooted into the old OS.
    GRUB_CFGS=""
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
        GRUB_CFGS="/boot/grub/grub.cfg"
    else
        MKCONFIG="$(command -v grub2-mkconfig || command -v grub-mkconfig)"
        for c in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
            [ -f "$c" ] && { "$MKCONFIG" -o "$c"; GRUB_CFGS="$GRUB_CFGS $c"; }
        done
        # RHEL/CentOS 7-8 UEFI keep the real config on the ESP; RHEL 9+ put
        # only a stub there (it contains "configfile") — leave stubs alone.
        for c in /boot/efi/EFI/*/grub.cfg; do
            [ -f "$c" ] || continue
            grep -q 'configfile' "$c" && continue
            "$MKCONFIG" -o "$c"; GRUB_CFGS="$GRUB_CFGS $c"
        done
    fi
    if [ -z "$GRUB_CFGS" ] || ! grep -qs "menuentry '${GRUB_TITLE}'" $GRUB_CFGS; then
        echo -e "${RED}Error: the installer entry did not make it into the GRUB configuration.${NC}"
        echo -e "${YELLOW}The disk has NOT been erased; the current system keeps booting normally.${NC}"
        exit 1
    fi

    # Now point the saved default at our entry by exact title. grub-set-default
    # writes grubenv, which GRUB_DEFAULT=saved reads at boot. Try persistent
    # set first, then grub-reboot as a one-shot guarantee for the next boot.
    if command -v grub-set-default >/dev/null 2>&1; then
        grub-set-default "${GRUB_TITLE}" 2>/dev/null || true
        grub-reboot "${GRUB_TITLE}" 2>/dev/null || true
    elif command -v grub2-set-default >/dev/null 2>&1; then
        grub2-set-default "${GRUB_TITLE}" 2>/dev/null || true
        grub2-reboot "${GRUB_TITLE}" 2>/dev/null || true
    fi
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo -e "\n${CYAN}❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊${NC}"
echo -e "${GREEN}${BOLD}                   OsNova Deployment Summary${NC}"
echo -e "${CYAN}❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊${NC}"
echo -e "  OS       : ${YELLOW}${DISPLAY_NAME}${NC}"
echo -e "  Disk     : ${YELLOW}${REAL_DISK}${NC}"
echo -e "  IP       : ${YELLOW}${V_IP}/${V_PREFIX}${NC}"
echo -e "  Gateway  : ${YELLOW}${V_GATEWAY}${NC}"
[ -n "$V_IP6" ] && echo -e "  IPv6     : ${YELLOW}${V_IP6}/${V_PREFIX6}${NC}"
echo -e "  SSH Port : ${YELLOW}${SSH_PORT}${NC}"
echo -e "  DNS      : ${YELLOW}${DNS_SERVERS}${NC}"

if [ "$PASSWORD_WAS_GENERATED" -eq 1 ]; then
    echo -e "  Password : ${YELLOW}${ROOT_PASS}${NC} ${RED}(generated automatically — save it now)${NC}"
else
    echo -e "  Password : ${GREEN}(custom password set)${NC}"
fi

echo -e "${CYAN}❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊❊${NC}"

if [ "$PASSWORD_WAS_GENERATED" -eq 1 ]; then
    echo -e "\n${RED}${BOLD}IMPORTANT: Save the generated root password before reboot:${NC} ${YELLOW}${ROOT_PASS}${NC}"
fi

# Ctrl+C during the countdown must leave a normally-booting system. For
# Debian the installer entry is already the GRUB default at this point, so
# undo that — otherwise the NEXT reboot, whenever it happens, would start
# the installer and wipe the disk.
revert_debian_grub() {
    echo -e "\n${YELLOW}Aborted — restoring the normal boot entry...${NC}"
    sed -i "/^menuentry '${GRUB_TITLE}'/,/^}/d" /etc/grub.d/40_custom 2>/dev/null || true
    if command -v grub-set-default >/dev/null 2>&1; then
        grub-set-default 0 2>/dev/null || true
    elif command -v grub2-set-default >/dev/null 2>&1; then
        grub2-set-default 0 2>/dev/null || true
    fi
    update-grub >/dev/null 2>&1 || {
        MKCONFIG="$(command -v grub2-mkconfig || command -v grub-mkconfig)"
        for c in $GRUB_CFGS; do "$MKCONFIG" -o "$c" >/dev/null 2>&1 || true; done
    }
    rm -f "${KERNEL_PATH}" "${INITRD_PATH}" 2>/dev/null || true
    echo -e "${CYAN}Aborted. The current system will boot normally.${NC}"
    exit 1
}
if [ "$OS_TYPE" = "debian" ]; then
    trap revert_debian_grub INT TERM
    echo -e "\n${YELLOW}Press Ctrl+C now to abort and restore normal booting.${NC}"
fi

if [ "$OS_TYPE" = "ubuntu" ]; then
    echo -e "\n${YELLOW}The disk has not been modified yet — press Ctrl+C now to abort safely.${NC}"
    echo -ne "Writing ${DISPLAY_NAME} to ${REAL_DISK} and rebooting in "
else
    echo -ne "\nRebooting into the Debian installer in "
fi
for i in {10..1}; do echo -n "$i... "; sleep 1; done
echo -e "\n${RED}${BOLD}Rebooting now!${NC}"
sync && sleep 2

if [ "$OS_TYPE" = "debian" ]; then
    reboot -f
else
    trap - EXIT INT TERM HUP PIPE   # no cleanup after the root fs goes read-only
    ubuntu_write_and_reboot
fi
