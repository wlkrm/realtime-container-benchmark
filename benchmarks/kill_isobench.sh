#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# IsoBench Emergency Kill Script
# ═══════════════════════════════════════════════════════════════════════
#
# Kills all leftover IsoBench processes, tears down network namespaces,
# bridges, cgroups, and AppArmor profiles. Use when a scenario hangs
# or a broadcast storm eats your system alive.
#
# Usage:
#   sudo bash benchmarks/kill_isobench.sh
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${YLW}[cleanup]${NC} $*"; }
ok()   { echo -e "${GRN}[  OK  ]${NC} $*"; }
err()  { echo -e "${RED}[FAILED]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:  sudo $0"
    exit 1
fi

# ── 1. Kill benchmark binaries ──────────────────────────────────────
log "Killing IsoBench processes..."
for name in cyclic cyclic_receiver ping pong seccomp_wrapper; do
    pids=$(pgrep -x "$name" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "  Killing $name (PIDs: $pids)"
        kill -9 $pids 2>/dev/null || true
    fi
done
# Also kill anything that lives inside our netns and was started via
# ip-netns-exec (shows up as children of "ip netns exec ...")
for pid in $(pgrep -f "ip netns exec ns" 2>/dev/null || true); do
    kill -9 "$pid" 2>/dev/null || true
done
ok "Processes killed"

# ── 2. Kill processes inside network namespaces ─────────────────────
log "Killing processes inside namespaces..."
for ns in ns1 ns2 ns_mid; do
    if ip netns list 2>/dev/null | grep -qw "$ns"; then
        ip netns pids "$ns" 2>/dev/null | while read -r pid; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
done
ok "Namespace processes killed"

# ── 3. Remove network namespaces ────────────────────────────────────
log "Removing network namespaces..."
for ns in ns1 ns2 ns_mid; do
    ip netns del "$ns" 2>/dev/null && echo "  Deleted $ns" || true
done
ok "Namespaces removed"

# ── 4. Remove bridges and leftover veth interfaces ──────────────────
log "Removing bridges and veth interfaces..."
for dev in br0 br_left br_right br_mid; do
    ip link del "$dev" 2>/dev/null && echo "  Deleted $dev" || true
done
for dev in veth1-br veth2-br veth_mid1_br veth_mid2_br; do
    ip link del "$dev" 2>/dev/null && echo "  Deleted $dev" || true
done
ok "Network devices removed"

# ── 5. Flush stale iptables rules ──────────────────────────────────
log "Flushing IsoBench iptables rules..."
for dev in veth1-br veth2-br veth_mid1_br veth_mid2_br; do
    iptables -D FORWARD -m physdev --physdev-in  "$dev" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-out "$dev" -j ACCEPT 2>/dev/null || true
done
ok "iptables rules cleaned"

# ── 6. Remove cgroups ──────────────────────────────────────────────
CGROUP_BENCH="/sys/fs/cgroup/isobench"
if [[ -d "$CGROUP_BENCH" ]]; then
    log "Removing cgroups..."
    for cg in "$CGROUP_BENCH"/*/; do
        [[ -d "$cg" ]] || continue
        # Move tasks back to root cgroup
        while read -r pid; do
            echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        done < <(cat "$cg/cgroup.procs" 2>/dev/null)
        rmdir "$cg" 2>/dev/null && echo "  Removed $cg" || true
    done
    rmdir "$CGROUP_BENCH" 2>/dev/null || true
    ok "Cgroups removed"
else
    ok "No cgroups to clean"
fi

# ── 7. Unload AppArmor profile ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v apparmor_parser &>/dev/null && [[ -f "$SCRIPT_DIR/isobench.apparmor" ]]; then
    log "Unloading AppArmor profile..."
    apparmor_parser -R "$SCRIPT_DIR/isobench.apparmor" 2>/dev/null && ok "AppArmor unloaded" || ok "AppArmor was not loaded"
else
    ok "AppArmor: nothing to do"
fi

echo ""
echo -e "${GRN}All clean.${NC} Your system should be back to normal."
