#!/usr/bin/env bash
# net-fix-ipv6.sh — diagnose and repair an IPv6 blackhole that stalls Emacs.
#
# Verdict from `M-x my/net-doctor` (2026-11-17):
#   curl IPv4 -> every site ok (<1.6s)
#   curl IPv6 -> connection timed out (black-holed route)
#   url.el    -> hung 15s while curl succeeded: Emacs dials the AAAA address
#                first, has no Happy Eyeballs, and waits out the OS timeout.
#
# Emacs has no "prefer IPv4" knob, so the fix belongs to the OS.
#
# Usage:
#   ./net-fix-ipv6.sh check          # read-only diagnosis (no root needed)
#   sudo ./net-fix-ipv6.sh prefer-ipv4   # recommended: IPv4-first sorting
#   sudo ./net-fix-ipv6.sh disable-ipv6  # nuclear option: kernel-off IPv6
#
# After either repair: rerun `M-x my/net-doctor`; the url.el line must say
# "ok".  That is the acceptance test.

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf '%b\n' "$*"; }

do_check() {
    say "${YELLOW}== IPv6 blackhole check (read-only) ==${NC}"

    say "\n-- IPv6 addresses on this machine --"
    ip -6 addr show scope global 2>/dev/null || say "(none found)"

    say "\n-- IPv6 default routes --"
    if ip -6 route show default 2>/dev/null | grep -q .; then
        ip -6 route show default
        say "${YELLOW}A default v6 route exists; if nothing answers (next test),${NC}"
        say "${YELLOW}packets are being silently dropped = blackhole.${NC}"
    else
        say "(no default IPv6 route)"
    fi

    say "\n-- DNS address ordering for news.ycombinator.com (RFC 6724) --"
    say "Emacs dials the first line getaddrinfo returns; curl races all of them:"
    getent ahosts news.ycombinator.com 2>/dev/null | awk '$1 ~ /:/ {v6++} $1 ~ /^[0-9.]+$/ {v4++} {print}' | head -8
    say "lines with colons = AAAA (IPv6), plain numbers = A (IPv4)"

    say "\n-- live connectivity --"
    if curl -6 -sS -o /dev/null --connect-timeout 5 -m 8 https://news.ycombinator.com; then
        say "${GREEN}curl -6: ok${NC}"
    else
        say "${RED}curl -6: FAILED (exit $?) — black-holed or absent IPv6${NC}"
    fi
    if curl -4 -sS -o /dev/null --connect-timeout 5 -m 8 https://news.ycombinator.com; then
        say "${GREEN}curl -4: ok${NC}"
    else
        say "${RED}curl -4: FAILED (exit $?) — then the problem is bigger than IPv6${NC}"
    fi

    say "\n-- resolver (informational) --"
    resolvectl status 2>/dev/null | head -12 || cat /etc/resolv.conf 2>/dev/null | head -8
}

do_prefer_ipv4() {
    [ "$(id -u)" -eq 0 ] || { say "${RED}run with sudo: sudo ./net-fix-ipv6.sh prefer-ipv4${NC}"; exit 1; }
    local conf=/etc/gai.conf
    local line='precedence ::ffff:0:0/96  100'
    if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100\b' "$conf" 2>/dev/null; then
        say "${GREEN}/etc/gai.conf already prefers IPv4 — nothing to do.${NC}"
    else
        [ -f "$conf" ] && cp -a "$conf" "$conf.bak.$(date +%Y%m%d-%H%M%S)" \
            && say "backed up $conf"
        # Add a comment banner so the change is self-explaining.
        printf '\n# Prefer IPv4 when a host offers both A and AAAA (fixes Emacs url.el\n\
# black-holed-IPv6 hangs; glibc RFC 6724 policy, read at next lookup).\n%s\n' \
            "$line" >> "$conf"
        say "${GREEN}added 'precedence ::ffff:0:0/96 100' to /etc/gai.conf${NC}"
    fi
    say "This makes getaddrinfo sort A records before AAAA. No reboot needed:"
    say "new lookups pick it up immediately. Verify:"
    getent ahosts news.ycombinator.com | head -4
    say "\n${GREEN}Now rerun M-x my/net-doctor in Emacs; the url.el line must say \"ok\".${NC}"
}

do_disable_ipv6() {
    [ "$(id -u)" -eq 0 ] || { say "${RED}run with sudo: sudo ./net-fix-ipv6.sh disable-ipv6${NC}"; exit 1; }
    say "${YELLOW}Nuclear option: IPv6 off at kernel level until reboot (persist below).${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    cat > /etc/sysctl.d/99-ipv6-off.conf <<'EOF'
# IPv6 disabled: black-holed route stalled Emacs url.el (no Happy Eyeballs).
# Remove this file to re-enable IPv6 after fixing the router/VPN.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    say "${GREEN}persisted to /etc/sysctl.d/99-ipv6-off.conf${NC}"
    say "Note: NetworkManager or a VPN agent may re-enable IPv6; if so, prefer"
    say "the 'prefer-ipv4' mode, which does not fight the network stack."
    say "\n${GREEN}Now rerun M-x my/net-doctor in Emacs; the url.el line must say \"ok\".${NC}"
}

case "${1:-check}" in
    check)        do_check ;;
    prefer-ipv4)  do_prefer_ipv4 ;;
    disable-ipv6) do_disable_ipv6 ;;
    *) say "usage: $0 {check|prefer-ipv4|disable-ipv6}"; exit 2 ;;
esac
