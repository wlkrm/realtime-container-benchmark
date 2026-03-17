#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# IsoBench Isolation Benchmark Suite
# ═══════════════════════════════════════════════════════════════════════
#
# Iterates through isolation techniques that might affect real-time
# performance and runs the cyclic + ping-pong benchmarks under each.
#
# Scenarios tested:
#   01_baseline          - No isolation, bare network namespaces
#   02_cgroup_cpuset     - cpuset cgroup limiting to specific CPUs
#   03_cgroup_mem         - memory cgroup with limits
#   04_cgroup_cpuset_mem  - cpuset + memory combined
#   05_cgroup_cpu_quota   - CPU bandwidth throttling (CFS quota)
#   06_seccomp_trivial    - Minimal 2-instr seccomp-bpf filter
#   07_seccomp_heavy      - 204-instr seccomp filter (Docker-like)
#   08_apparmor           - AppArmor enforce profile (all-allow)
#   09_netns_extra_hop    - Extra bridge hop (double-NAT topology)
#   10_all_light          - cgroup_cpuset + seccomp_trivial + apparmor
#   11_all_heavy          - cgroup_cpuset_mem + cpu_quota + seccomp_heavy + apparmor
#   12_pid_namespace      - PID namespace isolation
#   13_mount_namespace    - Mount namespace isolation
#   14_user_namespace     - User namespace remapping
#   15_cgroup_io_latency  - cgroup io.latency controller (blk-io accounting)
#   16_net_cls_cgroup     - net_cls cgroup tagging overhead
#   17_numa_membind       - NUMA memory binding (cross-node penalty)
#   18_cpu_stress         - RT under heavy CPU contention (stress-ng)
#   19_uts_ipc_namespace  - UTS + IPC namespace isolation combined
#   20_full_docker_like   - All namespaces + cgroups + seccomp (no Docker daemon)
#
# Usage:
#   bash benchmarks/run_isolation_suite.sh [--from N] [--bench LIST] [SCENARIO...]
#
# Options:
#   --bench LIST   Comma-separated list of benchmarks to run: cyclic,ping,uds
#                  (default: all three).  E.g. --bench uds  or  --bench cyclic,uds
#   --from N       Start from scenario N (prefix match), skip earlier ones
#
# Examples:
#   bash benchmarks/run_isolation_suite.sh              # all scenarios, all benchmarks
#   bash benchmarks/run_isolation_suite.sh 01_baseline  # just baseline
#   bash benchmarks/run_isolation_suite.sh 01 06 07     # prefix match
#   bash benchmarks/run_isolation_suite.sh --from 12    # start at 12, run to end
#   bash benchmarks/run_isolation_suite.sh --bench uds  # all scenarios, only UDS benchmark
#
# Results go into: benchmarks/results/<scenario>/
#
# Prerequisites:
#   - Root access
#   - Built binaries (cargo build --release)
#   - cgroup v2 unified hierarchy
#   - apparmor_parser (for AppArmor tests)
#   - gcc (for seccomp_wrapper)
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"

# ── Configurable parameters ─────────────────────────────────────────
ITERATIONS="${ISOBENCH_ITERATIONS:-60000}"        # ~60s at 1ms
CYCLE_TIME_US="${ISOBENCH_CYCLE_US:-1000}"       # 1ms default
INTERVAL_NS="${ISOBENCH_INTERVAL_NS:-1000000}"   # 1ms default
SENDER_CPU="${ISOBENCH_SENDER_CPU:-0}"
RECEIVER_CPU="${ISOBENCH_RECEIVER_CPU:-1}"
RT_PRIO="${ISOBENCH_PRIO:-90}"
SETTLE_TIME="${ISOBENCH_SETTLE:-3}"              # seconds between scenarios

# Binaries
CYCLIC="$PROJECT_DIR/target/release/cyclic"
PONG="$PROJECT_DIR/target/release/pong"
CYCLIC_RECV="$PROJECT_DIR/target/release/cyclic_receiver"
PING="$PROJECT_DIR/target/release/ping"
UDS_PONG="$PROJECT_DIR/target/release/uds_pong"
UDS_PING="$PROJECT_DIR/target/release/uds_ping"
SECCOMP_WRAPPER="$SCRIPT_DIR/seccomp_wrapper"
BRIDGE_SCRIPT="$PROJECT_DIR/scripts/bridge_network.sh"

# Network config (must match bridge_network.sh)
NS1="ns1"
NS2="ns2"
IP1="10.0.0.1"
IP2="10.0.0.2"
VETH1="veth1"
VETH2="veth2"

# UDS socket paths (placed in /tmp for universal access)
UDS_PONG_SOCK="/tmp/isobench_uds_pong.sock"

# cgroup paths (v2 unified)
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_BENCH="$CGROUP_ROOT/isobench"

# Colors for output
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

# ── Helper functions ────────────────────────────────────────────────
log()  { echo -e "${BLU}[isobench]${NC} $*"; }
ok()   { echo -e "${GRN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YLW}[ WARN ]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERROR ]${NC} $*" >&2; }

die() { err "$@"; exit 1; }

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log "sudo access required — you may be prompted for your password"
        sudo true || die "sudo authentication failed"
    fi
    ok "sudo access confirmed"
}

build_binaries() {
    log "Building release binaries..."
    (cd "$PROJECT_DIR" && cargo build --release -p testapps -p auswertung) \
        || die "Cargo build failed"
    for bin in "$CYCLIC" "$PONG" "$CYCLIC_RECV" "$PING" "$UDS_PONG" "$UDS_PING"; do
        [[ -x "$bin" ]] || die "Missing binary: $bin"
    done
    ok "Binaries ready"
}

build_seccomp_wrapper() {
    if [[ ! -x "$SECCOMP_WRAPPER" ]] || \
       [[ "$SCRIPT_DIR/seccomp_wrapper.c" -nt "$SECCOMP_WRAPPER" ]]; then
        log "Building seccomp_wrapper..."
        gcc -O2 -o "$SECCOMP_WRAPPER" "$SCRIPT_DIR/seccomp_wrapper.c" \
            || die "Failed to compile seccomp_wrapper"
        ok "seccomp_wrapper built"
    fi
}

setup_network() {
    log "Setting up network namespaces..."
    sudo bash "$BRIDGE_SCRIPT"
    ok "Network namespaces ready"
}

# ── cgroup v2 helpers ───────────────────────────────────────────────
cgroup_create() {
    local name="$1"
    local path="$CGROUP_BENCH/$name"
    sudo mkdir -p "$path"
    # Enable needed controllers
    echo "+cpuset +memory +cpu" | sudo tee "$CGROUP_ROOT/cgroup.subtree_control" >/dev/null 2>&1 || true
    echo "+cpuset +memory +cpu" | sudo tee "$CGROUP_BENCH/cgroup.subtree_control" >/dev/null 2>&1 || true
    echo "$path"
}

cgroup_cleanup() {
    # Kill any leftover processes and remove cgroup
    if [[ -d "$CGROUP_BENCH" ]]; then
        for cg in "$CGROUP_BENCH"/*/; do
            [[ -d "$cg" ]] || continue
            # Move tasks back to root
            while read -r pid; do
                echo "$pid" | sudo tee "$CGROUP_ROOT/cgroup.procs" >/dev/null 2>&1 || true
            done < <(sudo cat "$cg/cgroup.procs" 2>/dev/null) || true
            sudo rmdir "$cg" 2>/dev/null || true
        done
        sudo rmdir "$CGROUP_BENCH" 2>/dev/null || true
    fi
}

cgroup_add_pid() {
    local cg_path="$1"
    local pid="$2"
    echo "$pid" | sudo tee "$cg_path/cgroup.procs" >/dev/null
}

# ── AppArmor helpers ────────────────────────────────────────────────
apparmor_loaded=false

apparmor_load() {
    if command -v apparmor_parser &>/dev/null; then
        log "Loading AppArmor profile..."
        sudo apparmor_parser -r "$SCRIPT_DIR/isobench.apparmor" 2>/dev/null && {
            apparmor_loaded=true
            ok "AppArmor profile loaded"
        } || warn "AppArmor profile load failed (maybe AppArmor not enabled)"
    else
        warn "apparmor_parser not found, skipping AppArmor tests"
    fi
}

apparmor_unload() {
    if $apparmor_loaded && command -v apparmor_parser &>/dev/null; then
        sudo apparmor_parser -R "$SCRIPT_DIR/isobench.apparmor" 2>/dev/null || true
        apparmor_loaded=false
    fi
}

# ── Benchmark execution engine ──────────────────────────────────────
# Run a single benchmark scenario.
#
# Arguments:
#   $1 - scenario name (used as output prefix)
#   $2 - wrapper command for sender in ns1 (or "" for none)
#   $3 - wrapper command for receiver/pong in ns2 (or "" for none)
#   $4 - optional: cgroup path for sender
#   $5 - optional: cgroup path for receiver
#
# The function runs both the cyclic and ping-pong benchmarks.

run_scenario() {
    local name="$1"
    local wrap_sender="${2:-}"
    local wrap_receiver="${3:-}"
    local cg_sender="${4:-}"
    local cg_receiver="${5:-}"
    local outdir="$RESULTS_DIR/$name"

    mkdir -p "$outdir"
    log "━━━ Scenario: $name ━━━"

    # ── Cyclic benchmark ────────────────────────────────────────────
  if [[ -n "${BENCH_ENABLED[cyclic]:-}" ]]; then
    log "  Running cyclic benchmark..."

    # Start receiver in ns2
    local recv_cmd="$wrap_receiver $CYCLIC_RECV $VETH2 $IP2:9000 $ITERATIONS $CYCLE_TIME_US"
    sudo \
        ISOBENCH_PREFIX="${name}_cyclic" \
        ISOBENCH_OUTPUT_DIR="$outdir" \
        RUST_LOG=info \
        ip netns exec $NS2 env \
            ISOBENCH_PREFIX="${name}_cyclic" \
            ISOBENCH_OUTPUT_DIR="$outdir" \
            RUST_LOG=info \
            $recv_cmd &
    local recv_pid=$!

    # If cgroup specified for receiver, add it
    if [[ -n "$cg_receiver" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_receiver" "$recv_pid" 2>/dev/null || true
    fi

    sleep 1

    # Start sender in ns1
    local send_cmd="$wrap_sender $CYCLIC --target-addr=$IP2:9000 --interval-ns=$INTERVAL_NS --iterations=$ITERATIONS --cpu=$SENDER_CPU --priority=$RT_PRIO"
    sudo RUST_LOG=info ip netns exec $NS1 env RUST_LOG=info $send_cmd &
    local send_pid=$!

    if [[ -n "$cg_sender" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_sender" "$send_pid" 2>/dev/null || true
    fi

    # Wait for sender to finish (it has a fixed iteration count)
    wait "$send_pid" 2>/dev/null || true
    # Give receiver time to process remaining packets and write output
    sleep 2
    # SIGTERM first, then SIGKILL fallback (needed for PID-namespace scenarios
    # where the target is PID 1 and ignores SIGTERM)
    sudo kill "$recv_pid" 2>/dev/null || true
    sleep 0.5
    sudo kill -9 "$recv_pid" 2>/dev/null || true
    wait "$recv_pid" 2>/dev/null || true

    ok "  Cyclic done → $outdir"

    sleep "$SETTLE_TIME"
  else
    log "  Skipping cyclic benchmark (--bench filter)"
  fi

    # ── Ping-pong benchmark ─────────────────────────────────────────
  if [[ -n "${BENCH_ENABLED[ping]:-}" ]]; then
    log "  Running ping-pong benchmark..."

    # Start pong responder in ns2
    local pong_cmd="$wrap_receiver $PONG --bind-addr=$IP2:9000 --cpu=$RECEIVER_CPU --priority=$RT_PRIO"
    sudo RUST_LOG=info ip netns exec $NS2 env RUST_LOG=info $pong_cmd &
    local pong_pid=$!

    if [[ -n "$cg_receiver" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_receiver" "$pong_pid" 2>/dev/null || true
    fi

    sleep 1

    # Start ping sender in ns1
    # ping positional args: <iface> <pong_addr> <sample_limit> <cycle_time_us>
    local ping_cmd="$wrap_sender $PING $VETH1 $IP2:9000 $ITERATIONS $CYCLE_TIME_US"
    sudo \
        ISOBENCH_PREFIX="${name}_ping" \
        ISOBENCH_OUTPUT_DIR="$outdir" \
        RUST_LOG=info \
        ip netns exec $NS1 env \
            ISOBENCH_PREFIX="${name}_ping" \
            ISOBENCH_OUTPUT_DIR="$outdir" \
            RUST_LOG=info \
            $ping_cmd &
    local ping_pid=$!

    if [[ -n "$cg_sender" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_sender" "$ping_pid" 2>/dev/null || true
    fi

    wait "$ping_pid" 2>/dev/null || true
    sleep 2
    sudo kill "$pong_pid" 2>/dev/null || true
    sleep 0.5
    sudo kill -9 "$pong_pid" 2>/dev/null || true
    wait "$pong_pid" 2>/dev/null || true

    ok "  Ping-pong done → $outdir"

    sleep "$SETTLE_TIME"
  else
    log "  Skipping ping-pong benchmark (--bench filter)"
  fi

    # ── UDS ping-pong benchmark ──────────────────────────────────────
  if [[ -n "${BENCH_ENABLED[uds]:-}" ]]; then
    log "  Running UDS ping-pong benchmark..."

    # Clean up any stale socket files
    sudo rm -f "$UDS_PONG_SOCK" "${UDS_PONG_SOCK}.ping.sock"

    # Start UDS pong responder (no network namespace needed — pure IPC)
    local uds_pong_cmd="$wrap_receiver $UDS_PONG --uds-path=$UDS_PONG_SOCK --cpu=$RECEIVER_CPU --priority=$RT_PRIO"
    sudo RUST_LOG=info $uds_pong_cmd &
    local uds_pong_pid=$!

    if [[ -n "$cg_receiver" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_receiver" "$uds_pong_pid" 2>/dev/null || true
    fi

    sleep 1

    # Start UDS ping sender
    # uds_ping positional args: <pong_socket_path> <sample_limit> <cycle_time_us>
    local uds_ping_cmd="$wrap_sender $UDS_PING $UDS_PONG_SOCK $ITERATIONS $CYCLE_TIME_US"
    sudo \
        ISOBENCH_PREFIX="${name}_uds" \
        ISOBENCH_OUTPUT_DIR="$outdir" \
        RUST_LOG=info \
        env \
            ISOBENCH_PREFIX="${name}_uds" \
            ISOBENCH_OUTPUT_DIR="$outdir" \
            RUST_LOG=info \
            $uds_ping_cmd &
    local uds_ping_pid=$!

    if [[ -n "$cg_sender" ]]; then
        sleep 0.2
        cgroup_add_pid "$cg_sender" "$uds_ping_pid" 2>/dev/null || true
    fi

    wait "$uds_ping_pid" 2>/dev/null || true
    sleep 2
    sudo kill "$uds_pong_pid" 2>/dev/null || true
    sleep 0.5
    sudo kill -9 "$uds_pong_pid" 2>/dev/null || true
    wait "$uds_pong_pid" 2>/dev/null || true

    # Clean up socket files
    sudo rm -f "$UDS_PONG_SOCK" "${UDS_PONG_SOCK}.ping.sock"

    ok "  UDS ping-pong done → $outdir"

    sleep "$SETTLE_TIME"
  else
    log "  Skipping UDS benchmark (--bench filter)"
  fi
}

# ── Scenario definitions ────────────────────────────────────────────

scenario_01_baseline() {
    run_scenario "01_baseline" "" ""
}

scenario_02_cgroup_cpuset() {
    local cg
    cg=$(cgroup_create "cpuset_bench")
    # Limit to specific CPUs — same ones the RT apps want, so it's not
    # starving them, but the cgroup overhead is present.
    echo "$SENDER_CPU,$RECEIVER_CPU" | sudo tee "$cg/cpuset.cpus" >/dev/null
    echo "0" | sudo tee "$cg/cpuset.mems" >/dev/null 2>&1 || true
    run_scenario "02_cgroup_cpuset" "" "" "$cg" "$cg"
    cgroup_cleanup
}

scenario_03_cgroup_mem() {
    local cg
    cg=$(cgroup_create "mem_bench")
    # 512MB limit — generous, but the accounting overhead is there
    echo "536870912" | sudo tee "$cg/memory.max" >/dev/null
    echo "536870912" | sudo tee "$cg/memory.high" >/dev/null
    run_scenario "03_cgroup_mem" "" "" "$cg" "$cg"
    cgroup_cleanup
}

scenario_04_cgroup_cpuset_mem() {
    local cg
    cg=$(cgroup_create "cpuset_mem_bench")
    echo "$SENDER_CPU,$RECEIVER_CPU" | sudo tee "$cg/cpuset.cpus" >/dev/null
    echo "0" | sudo tee "$cg/cpuset.mems" >/dev/null 2>&1 || true
    echo "536870912" | sudo tee "$cg/memory.max" >/dev/null
    echo "536870912" | sudo tee "$cg/memory.high" >/dev/null
    run_scenario "04_cgroup_cpuset_mem" "" "" "$cg" "$cg"
    cgroup_cleanup
}

scenario_05_cgroup_cpu_quota() {
    local cg
    cg=$(cgroup_create "cpu_quota_bench")
    # CFS bandwidth: 950ms every 1000ms (95% quota)
    # This is generous but CFS throttling can cause latency spikes
    # when the RT task gets preempted at period boundaries.
    echo "950000 1000000" | sudo tee "$cg/cpu.max" >/dev/null
    run_scenario "05_cgroup_cpu_quota" "" "" "$cg" "$cg"
    cgroup_cleanup
}

scenario_06_seccomp_trivial() {
    run_scenario "06_seccomp_trivial" \
        "$SECCOMP_WRAPPER trivial" \
        "$SECCOMP_WRAPPER trivial"
}

scenario_07_seccomp_heavy() {
    run_scenario "07_seccomp_heavy" \
        "$SECCOMP_WRAPPER heavy" \
        "$SECCOMP_WRAPPER heavy"
}

scenario_08_apparmor() {
    if ! $apparmor_loaded; then
        warn "Skipping AppArmor scenario (profile not loaded)"
        return
    fi
    if ! command -v aa-exec &>/dev/null; then
        warn "Skipping AppArmor scenario (aa-exec not found)"
        return
    fi
    run_scenario "08_apparmor" \
        "aa-exec -p isobench --" \
        "aa-exec -p isobench --"
}

scenario_09_netns_extra_hop() {
    # Extra bridge hop (double-NAT topology).
    # Chain: ns1/veth1 ↔ br_left ↔ ns_mid(br_mid) ↔ br_right ↔ ns2/veth2
    #
    # The previous implementation attached both mid-veth peers back to br0,
    # which created an L2 loop (broadcast storm → 100 % CPU on every core).
    # Fix: detach ns1/ns2 from br0, use two separate host bridges.
    log "  Setting up extra-hop network topology..."

    # ── Detach ns1/ns2 veths from the single br0 ───────────────────
    sudo ip link set veth1-br nomaster
    sudo ip link set veth2-br nomaster

    # ── Create middle namespace ─────────────────────────────────────
    sudo ip netns add ns_mid

    # ── Create veth pairs connecting host ↔ ns_mid ──────────────────
    sudo ip link add veth_mid1 type veth peer name veth_mid1_br
    sudo ip link add veth_mid2 type veth peer name veth_mid2_br

    # Move one end of each pair into ns_mid
    sudo ip link set veth_mid1 netns ns_mid
    sudo ip link set veth_mid2 netns ns_mid

    # Bridge inside ns_mid
    sudo ip netns exec ns_mid ip link add br_mid type bridge
    sudo ip netns exec ns_mid ip link set veth_mid1 master br_mid
    sudo ip netns exec ns_mid ip link set veth_mid2 master br_mid
    sudo ip netns exec ns_mid ip link set br_mid up
    sudo ip netns exec ns_mid ip link set veth_mid1 up
    sudo ip netns exec ns_mid ip link set veth_mid2 up
    sudo ip netns exec ns_mid ip link set lo up

    # ── Two host-side bridges (no loop!) ────────────────────────────
    sudo ip link add br_left type bridge
    sudo ip link add br_right type bridge

    # br_left: ns1 side
    sudo ip link set veth1-br master br_left
    sudo ip link set veth_mid1_br master br_left
    sudo ip link set br_left up
    sudo ip link set veth1-br up
    sudo ip link set veth_mid1_br up

    # br_right: ns2 side
    sudo ip link set veth2-br master br_right
    sudo ip link set veth_mid2_br master br_right
    sudo ip link set br_right up
    sudo ip link set veth2-br up
    sudo ip link set veth_mid2_br up

    # iptables rules for the new interfaces
    sudo iptables -I FORWARD -m physdev --physdev-in veth_mid1_br -j ACCEPT 2>/dev/null || true
    sudo iptables -I FORWARD -m physdev --physdev-out veth_mid1_br -j ACCEPT 2>/dev/null || true
    sudo iptables -I FORWARD -m physdev --physdev-in veth_mid2_br -j ACCEPT 2>/dev/null || true
    sudo iptables -I FORWARD -m physdev --physdev-out veth_mid2_br -j ACCEPT 2>/dev/null || true

    run_scenario "09_netns_extra_hop" "" ""

    # ── Cleanup extra topology ──────────────────────────────────────
    sudo iptables -D FORWARD -m physdev --physdev-in veth_mid1_br -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -m physdev --physdev-out veth_mid1_br -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -m physdev --physdev-in veth_mid2_br -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -m physdev --physdev-out veth_mid2_br -j ACCEPT 2>/dev/null || true

    sudo ip netns del ns_mid 2>/dev/null || true
    sudo ip link del veth_mid1_br 2>/dev/null || true
    sudo ip link del veth_mid2_br 2>/dev/null || true
    sudo ip link del br_left 2>/dev/null || true
    sudo ip link del br_right 2>/dev/null || true

    # ── Restore original br0 topology ───────────────────────────────
    sudo ip link set veth1-br master br0
    sudo ip link set veth2-br master br0
    sudo ip link set veth1-br up
    sudo ip link set veth2-br up
}

scenario_10_all_light() {
    # Combined: cpuset cgroup + trivial seccomp + apparmor
    local cg
    cg=$(cgroup_create "light_bench")
    echo "$SENDER_CPU,$RECEIVER_CPU" | sudo tee "$cg/cpuset.cpus" >/dev/null
    echo "0" | sudo tee "$cg/cpuset.mems" >/dev/null 2>&1 || true

    local aa_wrap=""
    if $apparmor_loaded && command -v aa-exec &>/dev/null; then
        aa_wrap="aa-exec -p isobench --"
    fi

    run_scenario "10_all_light" \
        "$aa_wrap $SECCOMP_WRAPPER trivial" \
        "$aa_wrap $SECCOMP_WRAPPER trivial" \
        "$cg" "$cg"
    cgroup_cleanup
}

scenario_11_all_heavy() {
    # Combined: cpuset+mem cgroup + cpu quota + heavy seccomp + apparmor
    local cg
    cg=$(cgroup_create "heavy_bench")
    echo "$SENDER_CPU,$RECEIVER_CPU" | sudo tee "$cg/cpuset.cpus" >/dev/null
    echo "0" | sudo tee "$cg/cpuset.mems" >/dev/null 2>&1 || true
    echo "536870912" | sudo tee "$cg/memory.max" >/dev/null
    echo "536870912" | sudo tee "$cg/memory.high" >/dev/null
    echo "950000 1000000" | sudo tee "$cg/cpu.max" >/dev/null

    local aa_wrap=""
    if $apparmor_loaded && command -v aa-exec &>/dev/null; then
        aa_wrap="aa-exec -p isobench --"
    fi

    run_scenario "11_all_heavy" \
        "$aa_wrap $SECCOMP_WRAPPER heavy" \
        "$aa_wrap $SECCOMP_WRAPPER heavy" \
        "$cg" "$cg"
    cgroup_cleanup
}

scenario_12_pid_namespace() {
    # Run processes in an additional PID namespace (inside their netns).
    # unshare --pid --fork adds the PID ns isolation layer.
    # --kill-child ensures that when unshare receives a signal it forwards
    # it to the child (PID 1 in the new namespace), which otherwise would
    # silently ignore SIGTERM due to PID-1 special signal semantics.
    run_scenario "12_pid_namespace" \
        "unshare --pid --fork --kill-child --" \
        "unshare --pid --fork --kill-child --"
}

scenario_13_mount_namespace() {
    # Run with private mount namespace — tests VFS overhead of mount isolation.
    run_scenario "13_mount_namespace" \
        "unshare --mount --propagation private --" \
        "unshare --mount --propagation private --"
}

scenario_14_user_namespace() {
    # User namespace with identity UID/GID mapping.
    # The kernel still runs the user-ns security hooks on every operation.
    # We map root→root so the RT app still works, but the namespace overhead is present.
    #
    # Kernel ≥6.12 refuses to exec binaries owned by UIDs that are unmapped
    # in the new user namespace.  Since our binaries are owned by a regular
    # user (not root), we copy them to a temp dir and chown root:root so
    # the UID 0→0 mapping covers them.
    #
    # Inside a user namespace the process loses CAP_SYS_NICE and
    # CAP_IPC_LOCK in the *init* user namespace, so sched_setscheduler()
    # and mlockall() fail.  We work around this by:
    #   - Using  chrt --fifo  to set RT scheduling *before* entering the userns
    #   - Using  prlimit --memlock=unlimited  to raise RLIMIT_MEMLOCK *before*
    #     entering the userns so the kernel allows mlockall() inside.
    # The Rust binaries' own set_fifo / mlockall calls will still fail
    # (non-fatal inspect_err), but the inherited policy/rlimit is sufficient.
    local tmpdir
    tmpdir=$(mktemp -d /tmp/isobench_userns.XXXXXX)
    # The directory must be traversable inside the user namespace where
    # only UID 0→0 is mapped.  mktemp creates it mode 0700 owned by the
    # calling user (unmapped inside the userns), so fix ownership+mode.
    sudo chown root:root "$tmpdir"
    sudo chmod 755 "$tmpdir"
    log "  Copying binaries → $tmpdir (root-owned for user-ns exec)..."
    for bin in "$CYCLIC" "$PONG" "$CYCLIC_RECV" "$PING" "$UDS_PONG" "$UDS_PING"; do
        sudo cp "$bin" "$tmpdir/"
        sudo chown root:root "$tmpdir/$(basename "$bin")"
        sudo chmod 755 "$tmpdir/$(basename "$bin")"
    done

    # Inside a user namespace CAP_DAC_OVERRIDE/CAP_DAC_READ_SEARCH are
    # scoped to the *new* user namespace and do NOT bypass permission
    # checks on the host filesystem.  If any directory component on the
    # path to the real results dir (e.g. /home/<user>) has mode 700/750,
    # the userns process cannot traverse it → EACCES on file writes.
    #
    # Work-around: stage output into a /tmp directory (world-accessible)
    # and copy results to the real results dir after the benchmark.
    local userns_outdir
    userns_outdir=$(mktemp -d /tmp/isobench_userns_out.XXXXXX)
    sudo chown root:root "$userns_outdir"
    sudo chmod 755 "$userns_outdir"

    # Temporarily override binary paths
    local orig_cyclic="$CYCLIC" orig_pong="$PONG"
    local orig_recv="$CYCLIC_RECV" orig_ping="$PING"
    local orig_uds_pong="$UDS_PONG" orig_uds_ping="$UDS_PING"
    CYCLIC="$tmpdir/cyclic"
    PONG="$tmpdir/pong"
    CYCLIC_RECV="$tmpdir/cyclic_receiver"
    PING="$tmpdir/ping"
    UDS_PONG="$tmpdir/uds_pong"
    UDS_PING="$tmpdir/uds_ping"

    # Temporarily redirect RESULTS_DIR to the /tmp staging area so that
    # run_scenario (and the binaries it launches) write there.
    local orig_results_dir="$RESULTS_DIR"
    RESULTS_DIR="$userns_outdir"

    # chrt sets SCHED_FIFO before entering the user namespace (where
    # CAP_SYS_NICE is not available in init_user_ns).
    # prlimit raises RLIMIT_MEMLOCK so mlockall() succeeds inside the userns.
    run_scenario "14_user_namespace" \
        "chrt --fifo $RT_PRIO prlimit --memlock=unlimited:unlimited -- unshare --user --map-root-user --" \
        "chrt --fifo $RT_PRIO prlimit --memlock=unlimited:unlimited -- unshare --user --map-root-user --"

    # Restore RESULTS_DIR and copy staged output to the real location
    RESULTS_DIR="$orig_results_dir"
    local real_outdir="$RESULTS_DIR/14_user_namespace"
    mkdir -p "$real_outdir"
    sudo cp -a "$userns_outdir/14_user_namespace/"* "$real_outdir/" 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" "$real_outdir" 2>/dev/null || true
    sudo rm -rf "$userns_outdir"

    # Restore original paths and clean up
    CYCLIC="$orig_cyclic"
    PONG="$orig_pong"
    CYCLIC_RECV="$orig_recv"
    PING="$orig_ping"
    UDS_PONG="$orig_uds_pong"
    UDS_PING="$orig_uds_ping"
    sudo rm -rf "$tmpdir"
}

scenario_15_cgroup_io_latency() {
    # cgroup v2 io.latency controller — forces the kernel to track per-cgroup
    # block-I/O latencies and can throttle/prioritise I/O.  Even when the RT
    # workload is pure network (no disk I/O), the accounting hooks fire on
    # every cgroup context switch and can add measurable overhead.
    local cg
    cg=$(cgroup_create "io_lat_bench")
    # Enable io controller in subtree
    echo "+io" | sudo tee "$CGROUP_BENCH/cgroup.subtree_control" >/dev/null 2>&1 || true
    # Set a 1ms target latency on all block devices (triggers accounting)
    # Format: "MAJ:MIN target=<us>".  We apply to all devices found.
    for dev in /sys/block/*/dev; do
        [[ -f "$dev" ]] || continue
        local majmin
        majmin=$(cat "$dev")
        echo "$majmin target=1000" | sudo tee "$cg/io.latency" >/dev/null 2>&1 || true
    done
    run_scenario "15_cgroup_io_latency" "" "" "$cg" "$cg"
    cgroup_cleanup
}

scenario_16_net_cls_cgroup() {
    # net_cls / net_prio cgroup — attaches a classid to every packet sent by
    # processes in this cgroup.  The kernel adds an skb->priority lookup on
    # every sendmsg/recvmsg path which can perturb latency measurements.
    # On cgroup v2 the BPF-based equivalent is used when available.
    local cg
    cg=$(cgroup_create "net_cls_bench")
    # If cgroup v1 net_cls is mounted, set a classid
    if [[ -d /sys/fs/cgroup/net_cls ]]; then
        local v1cg="/sys/fs/cgroup/net_cls/isobench"
        sudo mkdir -p "$v1cg"
        echo "0x00100001" | sudo tee "$v1cg/net_cls.classid" >/dev/null 2>&1 || true
    fi
    # On cgroup v2, apply a trivial tc BPF filter that classifies via cgroup
    # (adds the per-packet cgroup lookup overhead)
    # Attach a simple matchall + cgroup action to both veth bridges
    for iface in veth1-br veth2-br; do
        sudo tc qdisc replace dev "$iface" root prio 2>/dev/null || true
        sudo tc filter add dev "$iface" parent 1:0 protocol all matchall \
            action skbedit priority 1 2>/dev/null || true
    done
    run_scenario "16_net_cls_cgroup" "" "" "$cg" "$cg"
    # Cleanup tc
    for iface in veth1-br veth2-br; do
        sudo tc qdisc del dev "$iface" root 2>/dev/null || true
    done
    if [[ -d /sys/fs/cgroup/net_cls/isobench ]]; then
        sudo rmdir /sys/fs/cgroup/net_cls/isobench 2>/dev/null || true
    fi
    cgroup_cleanup
}

scenario_17_numa_membind() {
    # NUMA memory binding — on multi-socket systems, binding memory to a
    # remote NUMA node forces cross-interconnect (QPI/UPI/Infinity Fabric)
    # memory accesses for every stack variable, heap alloc, and kernel buffer.
    # On single-node systems this still exercises the membind path overhead.
    if ! command -v numactl &>/dev/null; then
        warn "Skipping NUMA scenario (numactl not found)"
        return
    fi
    local max_node
    max_node=$(numactl --hardware 2>/dev/null | awk '/^available:/{print $2-1}')
    if [[ -z "$max_node" ]] || [[ "$max_node" -lt 0 ]]; then
        max_node=0
    fi
    # Bind to the highest NUMA node (farthest from CPU 0 on multi-socket)
    run_scenario "17_numa_membind" \
        "numactl --membind=$max_node --" \
        "numactl --membind=$max_node --"
}

scenario_18_cpu_stress() {
    # Run the RT benchmark while all other CPUs are under heavy load.
    # stress-ng saturates every CPU *except* the RT-pinned ones with
    # mixed workloads (cpu + cache + memory), creating realistic
    # contention for shared resources: LLC, memory bandwidth, interconnect.
    if ! command -v stress-ng &>/dev/null; then
        warn "Skipping CPU-stress scenario (stress-ng not found)"
        return
    fi
    local total_cpus
    total_cpus=$(nproc)
    # Number of stressor workers = total CPUs minus the two RT-pinned ones
    local n_stressors=$(( total_cpus > 2 ? total_cpus - 2 : 1 ))
    log "  Starting stress-ng with $n_stressors workers (avoiding CPUs $SENDER_CPU,$RECEIVER_CPU)..."
    # Build a CPU set that excludes the RT CPUs
    local stress_cpus=""
    for (( c=0; c<total_cpus; c++ )); do
        if [[ $c -ne $SENDER_CPU ]] && [[ $c -ne $RECEIVER_CPU ]]; then
            [[ -n "$stress_cpus" ]] && stress_cpus+=","
            stress_cpus+="$c"
        fi
    done
    [[ -z "$stress_cpus" ]] && stress_cpus="0"
    sudo taskset -c "$stress_cpus" stress-ng \
        --cpu "$n_stressors" \
        --cache "$n_stressors" \
        --vm 1 --vm-bytes 128M \
        --timeout 0 --quiet &
    local stress_pid=$!
    sleep 2  # let stressors ramp up

    run_scenario "18_cpu_stress" "" ""

    sudo kill "$stress_pid" 2>/dev/null || true
    wait "$stress_pid" 2>/dev/null || true
    ok "  stress-ng stopped"
}

scenario_19_uts_ipc_namespace() {
    # Combined UTS + IPC namespace isolation.
    # UTS namespace: independent hostname/domainname — tests the nsproxy
    # overhead on every syscall that touches utsname.
    # IPC namespace: independent SysV IPC / POSIX mqueue — isolates shared
    # memory, semaphores, message queues.  The combined nsproxy indirection
    # can add latency to syscalls even when IPC is unused.
    run_scenario "19_uts_ipc_namespace" \
        "unshare --uts --ipc --fork --kill-child --" \
        "unshare --uts --ipc --fork --kill-child --"
}

scenario_20_full_docker_like() {
    # Full Docker-like isolation WITHOUT Docker daemon overhead.
    # Combines: PID ns + mount ns + UTS ns + IPC ns + user ns
    #         + cgroup (cpuset + memory + cpu quota)
    #         + heavy seccomp filter
    # This measures the kernel's cumulative overhead of all isolation
    # mechanisms that a typical container runtime applies.
    local cg
    cg=$(cgroup_create "docker_like_bench")
    echo "$SENDER_CPU,$RECEIVER_CPU" | sudo tee "$cg/cpuset.cpus" >/dev/null
    echo "0" | sudo tee "$cg/cpuset.mems" >/dev/null 2>&1 || true
    echo "536870912" | sudo tee "$cg/memory.max" >/dev/null
    echo "536870912" | sudo tee "$cg/memory.high" >/dev/null
    echo "950000 1000000" | sudo tee "$cg/cpu.max" >/dev/null

    # Full namespace stack + heavy seccomp.
    # chrt + prlimit before unshare so RT prio and memlock survive the userns.
    local wrap="chrt --fifo $RT_PRIO prlimit --memlock=unlimited:unlimited -- unshare --pid --mount --uts --ipc --user --map-root-user --fork --kill-child -- $SECCOMP_WRAPPER heavy"

    # Stage output in /tmp like scenario_14 (user-ns can't write to ~/...)
    local tmpdir userns_outdir
    tmpdir=$(mktemp -d /tmp/isobench_dockerlike_bin.XXXXXX)
    userns_outdir=$(mktemp -d /tmp/isobench_dockerlike_out.XXXXXX)
    sudo chown root:root "$tmpdir" "$userns_outdir"
    sudo chmod 755 "$tmpdir" "$userns_outdir"
    for bin in "$CYCLIC" "$PONG" "$CYCLIC_RECV" "$PING" "$UDS_PONG" "$UDS_PING"; do
        sudo cp "$bin" "$tmpdir/"
        sudo chown root:root "$tmpdir/$(basename "$bin")"
        sudo chmod 755 "$tmpdir/$(basename "$bin")"
    done

    local orig_cyclic="$CYCLIC" orig_pong="$PONG"
    local orig_recv="$CYCLIC_RECV" orig_ping="$PING"
    local orig_uds_pong="$UDS_PONG" orig_uds_ping="$UDS_PING"
    CYCLIC="$tmpdir/cyclic"
    PONG="$tmpdir/pong"
    CYCLIC_RECV="$tmpdir/cyclic_receiver"
    PING="$tmpdir/ping"
    UDS_PONG="$tmpdir/uds_pong"
    UDS_PING="$tmpdir/uds_ping"

    local orig_results_dir="$RESULTS_DIR"
    RESULTS_DIR="$userns_outdir"

    run_scenario "20_full_docker_like" "$wrap" "$wrap" "$cg" "$cg"

    RESULTS_DIR="$orig_results_dir"
    local real_outdir="$RESULTS_DIR/20_full_docker_like"
    mkdir -p "$real_outdir"
    sudo cp -a "$userns_outdir/20_full_docker_like/"* "$real_outdir/" 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" "$real_outdir" 2>/dev/null || true
    sudo rm -rf "$userns_outdir"

    CYCLIC="$orig_cyclic"
    PONG="$orig_pong"
    CYCLIC_RECV="$orig_recv"
    PING="$orig_ping"
    UDS_PONG="$orig_uds_pong"
    UDS_PING="$orig_uds_ping"
    sudo rm -rf "$tmpdir"
    cgroup_cleanup
}

# ── All scenarios in order ──────────────────────────────────────────
ALL_SCENARIOS=(
    01_baseline
    02_cgroup_cpuset
    03_cgroup_mem
    04_cgroup_cpuset_mem
    05_cgroup_cpu_quota
    06_seccomp_trivial
    07_seccomp_heavy
    08_apparmor
    09_netns_extra_hop
    10_all_light
    11_all_heavy
    12_pid_namespace
    13_mount_namespace
    14_user_namespace
    15_cgroup_io_latency
    16_net_cls_cgroup
    17_numa_membind
    18_cpu_stress
    19_uts_ipc_namespace
    20_full_docker_like
)

match_scenarios() {
    local pattern="$1"
    local matched=()
    for s in "${ALL_SCENARIOS[@]}"; do
        if [[ "$s" == "$pattern"* ]] || [[ "$s" == "$pattern" ]]; then
            matched+=("$s")
        fi
    done
    echo "${matched[@]}"
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    # ── Parse options ────────────────────────────────────────────────
    local start_from=""
    local bench_filter=""   # empty = all benchmarks
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from|--start-from)
                start_from="$2"
                shift 2
                ;;
            --from=*|--start-from=*)
                start_from="${1#*=}"
                shift
                ;;
            --bench|--benchmarks)
                bench_filter="$2"
                shift 2
                ;;
            --bench=*|--benchmarks=*)
                bench_filter="${1#*=}"
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # Build associative array of enabled benchmarks
    declare -A BENCH_ENABLED
    if [[ -z "$bench_filter" ]]; then
        BENCH_ENABLED=([cyclic]=1 [ping]=1 [uds]=1)
    else
        IFS=',' read -ra _parts <<< "$bench_filter"
        for _b in "${_parts[@]}"; do
            _b="$(echo "$_b" | tr -d ' ')"
            case "$_b" in
                cyclic|ping|uds) BENCH_ENABLED["$_b"]=1 ;;
                *) die "Unknown benchmark '$_b'. Valid: cyclic, ping, uds" ;;
            esac
        done
    fi
    export BENCH_ENABLED
    set -- "${positional[@]+"${positional[@]}"}"

    check_sudo

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  IsoBench Isolation Benchmark Suite"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Iterations: $ITERATIONS"
    echo "  Cycle:      ${CYCLE_TIME_US}µs"
    echo "  Interval:   ${INTERVAL_NS}ns"
    echo "  CPUs:       sender=$SENDER_CPU receiver=$RECEIVER_CPU"
    echo "  Priority:   $RT_PRIO"
    echo "  Output:     $RESULTS_DIR/"
    echo "  Benchmarks: $(IFS=,; echo "${!BENCH_ENABLED[*]}")"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Determine which scenarios to run
    local scenarios=()
    if [[ $# -gt 0 ]]; then
        for arg in "$@"; do
            local matched
            matched=$(match_scenarios "$arg")
            if [[ -z "$matched" ]]; then
                warn "No scenario matching '$arg'"
            else
                scenarios+=($matched)
            fi
        done
    else
        scenarios=("${ALL_SCENARIOS[@]}")
    fi

    # ── Apply --from filter: drop scenarios before the given prefix ──
    if [[ -n "$start_from" ]]; then
        local filtered=()
        local found=false
        for s in "${scenarios[@]}"; do
            if ! $found; then
                if [[ "$s" == "$start_from"* ]] || [[ "$s" == "$start_from" ]]; then
                    found=true
                fi
            fi
            if $found; then
                filtered+=("$s")
            fi
        done
        if [[ ${#filtered[@]} -eq 0 ]]; then
            die "--from '$start_from' did not match any scenario"
        fi
        scenarios=("${filtered[@]}")
    fi

    if [[ ${#scenarios[@]} -eq 0 ]]; then
        die "No scenarios to run"
    fi

    log "Will run ${#scenarios[@]} scenario(s): ${scenarios[*]}"

    # Build everything
    build_binaries
    build_seccomp_wrapper

    # Setup network
    setup_network

    # Load AppArmor if any scenario needs it
    for s in "${scenarios[@]}"; do
        if [[ "$s" == *apparmor* ]] || [[ "$s" == *all_light* ]] || [[ "$s" == *all_heavy* ]]; then
            apparmor_load
            break
        fi
    done

    # Ensure results dir exists
    mkdir -p "$RESULTS_DIR"

    # Record system info
    {
        echo "Date: $(date -Iseconds)"
        echo "Kernel: $(uname -r)"
        echo "Hostname: $(hostname)"
        echo "CPUs: $(nproc)"
        echo "RT kernel: $(uname -v)"
        echo ""
        echo "=== /proc/cmdline ==="
        cat /proc/cmdline 2>/dev/null || true
        echo ""
        echo "=== CPU info ==="
        lscpu 2>/dev/null || true
        echo ""
        echo "=== cgroup controllers ==="
        cat "$CGROUP_ROOT/cgroup.controllers" 2>/dev/null || true
        echo ""
        echo "=== AppArmor status ==="
        sudo aa-status 2>/dev/null || echo "(not available)"
        echo ""
        echo "=== Parameters ==="
        echo "ITERATIONS=$ITERATIONS"
        echo "CYCLE_TIME_US=$CYCLE_TIME_US"
        echo "INTERVAL_NS=$INTERVAL_NS"
        echo "SENDER_CPU=$SENDER_CPU"
        echo "RECEIVER_CPU=$RECEIVER_CPU"
        echo "RT_PRIO=$RT_PRIO"
    } > "$RESULTS_DIR/system_info.txt"
    ok "System info recorded"

    # Run scenarios
    local start_time=$SECONDS
    local completed=0
    local failed=0

    for scenario in "${scenarios[@]}"; do
        local fn="scenario_${scenario}"
        if declare -f "$fn" &>/dev/null; then
            log "Starting scenario: $scenario"
            if "$fn"; then
                ok "Completed: $scenario"
                completed=$((completed + 1))
            else
                err "Failed: $scenario"
                failed=$((failed + 1))
            fi
        else
            warn "No function for scenario: $scenario"
        fi
        # Clean up cgroups between scenarios
        cgroup_cleanup
    done

    # Cleanup
    apparmor_unload

    local elapsed=$((SECONDS - start_time))
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Suite complete: $completed passed, $failed failed"
    echo "  Elapsed: ${elapsed}s"
    echo "  Results: $RESULTS_DIR/"
    echo ""
    echo "  Run analysis:"
    echo "    python3 benchmarks/analyze_results.py $RESULTS_DIR"
    echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
