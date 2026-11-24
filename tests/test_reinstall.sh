#!/usr/bin/env bash
# Offline tests for os/reinstall.sh. Nothing here touches disks, GRUB or the
# network: the script is sourced with OSNOVA_LIB_ONLY=1, which loads only the
# helper functions, and commands with side effects are replaced by fakes.
#
#   bash tests/test_reinstall.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/os/reinstall.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
yes_() { if "$@"; then ok; else fail "expected true: $*"; fi; }
no_()  { if "$@"; then fail "expected false: $*"; else ok; fi; }
eq()   { if [ "$1" = "$2" ]; then ok; else fail "$3: got '$1', expected '$2'"; fi; }

# shellcheck disable=SC1090,SC1091  # sourced by path at run time
OSNOVA_LIB_ONLY=1 source "$SCRIPT"
set +e   # the script turns on errexit; the tests check exit codes themselves

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Validation ---------------------------------------------------------------
yes_ is_valid_password 'Abc123!@#%^*_+=.-'
no_  is_valid_password 'has space'
no_  is_valid_password 'dollar$'
no_  is_valid_password "quote'"
no_  is_valid_password ''

yes_ is_ipv4 192.0.2.1
yes_ is_ipv4 255.255.255.255
no_  is_ipv4 256.1.1.1
no_  is_ipv4 1.2.3
no_  is_ipv4 2001:db8::1

yes_ is_ipv6 2001:db8::1
yes_ is_ipv6 fe80::1
no_  is_ipv6 192.0.2.1
no_  is_ipv6 2001:db8:::1
no_  is_ipv6 1::2::3

# --- Address arithmetic -------------------------------------------------------
eq "$(prefix_to_mask 24)" 255.255.255.0 "prefix_to_mask 24"
eq "$(prefix_to_mask 20)" 255.255.240.0 "prefix_to_mask 20"
eq "$(prefix_to_mask 32)" 255.255.255.255 "prefix_to_mask 32"
eq "$(prefix_to_mask 0)" 0.0.0.0 "prefix_to_mask 0"

yes_ ipv4_in_subnet 192.0.2.10 24 192.0.2.1
no_  ipv4_in_subnet 192.0.2.10 24 198.51.100.1
yes_ gateway4_needs_onlink 192.0.2.10 32 192.0.2.1
yes_ gateway4_needs_onlink 192.0.2.10 24 198.51.100.1
no_  gateway4_needs_onlink 192.0.2.10 24 192.0.2.1

eq "$(ipv6_expand 2001:db8::1)" 20010db8000000000000000000000001 "ipv6_expand"
yes_ ipv6_in_subnet 2001:db8:1::10 64 2001:db8:1::1
no_  ipv6_in_subnet 2001:db8:1::10 64 2001:db8:2::1
yes_ gateway6_needs_onlink 2001:db8::10 128 2001:db8::1
no_  gateway6_needs_onlink 2001:db8::10 64 fe80::1
yes_ gateway6_needs_onlink 2001:db8:1::10 64 2001:db8:2::1

# --- Parsing ------------------------------------------------------------------
R='default via 192.0.2.1 dev eth0 proto static metric 100'
eq "$(route_field "$R" via)" 192.0.2.1 "route_field via"
eq "$(route_field "$R" dev)" eth0 "route_field dev"
eq "$(route_field 'default dev eth0 scope link' via)" "" "route_field without via"

eq "$(part_dev /dev/sda 1)" /dev/sda1 "part_dev sda"
eq "$(part_dev /dev/nvme0n1 1)" /dev/nvme0n1p1 "part_dev nvme"

# --- Fallback disk detection --------------------------------------------------
# Same choice as v2.2's `ls | grep`: first non-removable sd/vd/xvd/nvme/hd disk
# in name order; loop and removable devices are skipped.
SB="$TMP/sys_block"
for d in loop0:0 nvme0n1:0 sda:1 vda:0; do
    mkdir -p "$SB/${d%:*}"; echo "${d#*:}" > "$SB/${d%:*}/removable"
done
eq "$(OSNOVA_SYS_BLOCK="$SB" detect_disk_fallback)" /dev/nvme0n1 "detect_disk_fallback"
echo 1 > "$SB/nvme0n1/removable"
eq "$(OSNOVA_SYS_BLOCK="$SB" detect_disk_fallback)" /dev/vda "detect_disk_fallback skips removable"

# --- Writing the image --------------------------------------------------------
# write_image uses direct I/O, and falls back to a buffered write when the
# disk refuses it.
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/qemu-img" <<'EOF'
#!/bin/sh
echo "$*" >> "$QEMU_LOG"
case " $* " in *" -t none "*) [ "${QEMU_NO_DIRECT:-0}" = 1 ] && exit 1 ;; esac
exit 0
EOF
chmod +x "$FAKEBIN/qemu-img"
: > "$TMP/img.qcow2"
export QEMU_LOG="$TMP/qemu.log"

: > "$QEMU_LOG"
PATH="$FAKEBIN:$PATH" write_image "$TMP/img.qcow2" qcow2 /dev/fake
eq "$?" 0 "write_image status"
eq "$(cat "$QEMU_LOG")" "convert -f qcow2 -O raw -t none -p $TMP/img.qcow2 /dev/fake" "write_image direct"

: > "$QEMU_LOG"
QEMU_NO_DIRECT=1 PATH="$FAKEBIN:$PATH" write_image "$TMP/img.qcow2" qcow2 /dev/fake
eq "$?" 0 "write_image fallback status"
eq "$(sed -n 2p "$QEMU_LOG")" "convert -f qcow2 -O raw -p $TMP/img.qcow2 /dev/fake" "write_image buffered fallback"

body="$(sed -n '/^ubuntu_write_and_reboot() {/,/^}/p' "$SCRIPT")"
# shellcheck disable=SC2016  # literal text of the call
case "$body" in *'write_image "${WRITE_SRC}" "${WRITE_FMT}" "${REAL_DISK}"'*) ok ;;
    *) fail "ubuntu_write_and_reboot does not write through write_image" ;; esac
case "$body" in *"qemu-img convert"*) fail "ubuntu_write_and_reboot calls qemu-img directly" ;; *) ok ;; esac

# --- Version and changelog ----------------------------------------------------
V="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
eq "$(sed -n 's/^# Version: //p' "$SCRIPT")" "$V" "header version"

# --- README -------------------------------------------------------------------
README="$ROOT/README.md"
# Title, a one-line blockquote, then badges: aligned left, as the owner
# prefers (a centered header was tried and dropped).
eq "$(head -n 3 "$README" | cut -c1-2)" "$(printf '# \n\n> ')" "README header"
yes_ grep -qx '# OsNova' "$README"
no_  grep -q '<div' "$README"
# A table reads well when its cells are short and alike in length: one long
# cell widens its column and leaves blank space in every other row. So no
# cell over 60 characters, and in a column whose longest cell is over 30, the
# typical (median) cell is at least 40% of it.
UNEVEN="$(awk '
    function check(   c, i, j, n, tmp, longest, median) {
        for (c = 1; c <= ncol; c++) {
            n = 0
            for (i = 1; i <= nrow; i++) if ((i, c) in len) v[++n] = len[i, c]
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { tmp = v[i]; v[i] = v[j]; v[j] = tmp }
            if (n == 0) continue
            longest = v[n]; median = v[int(n / 2) + 1]
            if (longest > 60 || (longest > 30 && median < 0.4 * longest)) print "table at line " start ", column " c
        }
        nrow = 0; delete len
    }
    /^```/ { code = !code }
    !code && /^\|/ {
        if (nrow == 0 && !intable) { start = NR; header = 1 }
        intable = 1
        if ($0 ~ /^\|[-|: ]+\|$/) next
        if (header) { header = 0; ncol = split($0, h, / \| /); next }
        line = $0; gsub(/`|\*/, "", line); gsub(/\\\|/, "!", line)
        k = split(line, cells, / \| /)
        if (k != ncol) next
        nrow++
        for (c = 1; c <= k; c++) { x = cells[c]; gsub(/^\| *| *\|$|^ +| +$/, "", x); len[nrow, c] = length(x) }
        next
    }
    intable { check(); intable = 0 }
    END { if (intable) check() }
' "$README")"
eq "$UNEVEN" "" "README tables with uneven cells"
yes_ grep -q 'img.shields.io/github/v/release/harryheros/osnova' "$README"
no_  grep -q 'img.shields.io/badge/version-' "$README"   # a hand-written badge goes stale
no_  grep -qi 'novaod' "$README"                         # a free tool: no commercial licensing
eq "$(tail -n 1 "$README")" "Part of the [Nova infrastructure toolkit](https://github.com/harryheros)." "README last line"
# Every #anchor link points at a heading (GitHub's slug: lowercase, spaces to
# hyphens, punctuation dropped).
SLUGS="$(grep -E '^#{1,6} ' "$README" | sed -E 's/^#+ //; s/`//g' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g')"
while read -r a; do
    if grep -qxF "$a" <<<"$SLUGS"; then ok; else fail "README link #$a has no heading"; fi
done < <(grep -oE '\]\(#[^)]+\)' "$README" | sed -E 's/^\]\(#//; s/\)$//' | sort -u)
while read -r f; do
    yes_ test -e "$ROOT/$f"
done < <(grep -oE '\]\(\./[^)#]+' "$README" | sed -E 's/^\]\(\.\///' | sort -u)

HEADS="$(grep '^## ' "$ROOT/CHANGELOG.md")"
BAD="$(grep -vE '^## [0-9]+\.[0-9]+\.[0-9]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' <<<"$HEADS")"
eq "$BAD" "" "CHANGELOG headings must be '## X.Y.Z (YYYY-MM-DD)'"
VERS="$(sed -E 's/^## ([0-9.]+) .*/\1/' <<<"$HEADS")"
eq "$(head -n1 <<<"$VERS")" "$V" "newest CHANGELOG entry"
eq "$(tail -n1 <<<"$VERS")" 1.0.0 "oldest CHANGELOG entry"
eq "$VERS" "$(sort -t. -k1,1nr -k2,2nr -k3,3nr <<<"$VERS")" "CHANGELOG order (newest first)"

# --- Static checks ------------------------------------------------------------
yes_ bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
    yes_ shellcheck "$SCRIPT" "$0"
else
    echo "shellcheck not installed: skipped"
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
