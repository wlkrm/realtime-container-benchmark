#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# pre_rt_unshare.sh — Set RT scheduling + CPU affinity + mlockall BEFORE
# entering a user namespace, so the child inherits them.
#
# Inside a user namespace CAP_SYS_NICE and CAP_IPC_LOCK don't extend to
# the init user namespace, so calls like sched_setscheduler(SCHED_FIFO)
# and mlockall(MCL_CURRENT|MCL_FUTURE) fail with EPERM/ENOMEM.
#
# Solution: do those privileged ops first, then unshare.
#
# Usage:
#   pre_rt_unshare.sh <cpu> <priority> -- <command> [args...]
#
# Example:
#   pre_rt_unshare.sh 0 90 -- unshare --user --map-root-user -- ./cyclic ...
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

CPU="$1"; shift
PRIO="$1"; shift
[[ "$1" == "--" ]] && shift  # consume optional --

# Pin to CPU
taskset -cp "$CPU" $$ >/dev/null 2>&1

# Set SCHED_FIFO with requested priority
chrt -f -p "$PRIO" $$ >/dev/null 2>&1

# Lock current and future pages (best-effort; python fallback if C not available)
# mlockall is inherited across exec, but there's no standalone CLI tool.
# We rely on the RT scheduling + affinity being the critical inherited bits.
# The child binary's mlockall will still fail inside userns, so we handle
# that separately by making the binary tolerate the failure.

exec "$@"
