/*
 * seccomp_wrapper.c - Apply a seccomp-bpf filter then exec the target program.
 *
 * Usage: ./seccomp_wrapper <trivial|heavy> <program> [args...]
 *
 * Modes:
 *   trivial  - Minimal 2-instruction allow-all filter.
 *              Tests the base overhead of having seccomp-bpf active.
 *
 *   heavy    - Filter with ~200 conditional checks before allowing.
 *              Simulates a complex container seccomp profile (like Docker's).
 *              Every syscall traverses all 200 comparisons before ALLOW.
 *
 * The filter is fully permissive (all syscalls allowed), so the target
 * application runs normally. Only the per-syscall filter traversal overhead
 * is added.
 *
 * Build: gcc -O2 -o seccomp_wrapper seccomp_wrapper.c
 */

#define _GNU_SOURCE
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Architecture detection for seccomp */
#if defined(__x86_64__)
#define AUDIT_ARCH_CURRENT AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define AUDIT_ARCH_CURRENT AUDIT_ARCH_AARCH64
#elif defined(__i386__)
#define AUDIT_ARCH_CURRENT AUDIT_ARCH_I386
#elif defined(__arm__)
#define AUDIT_ARCH_CURRENT AUDIT_ARCH_ARM
#else
#error "Unsupported architecture for seccomp_wrapper"
#endif

/*
 * Trivial filter: 2 instructions
 *   0: Load architecture field
 *   1: Return ALLOW
 *
 * Minimal overhead: the kernel still enters the seccomp path for each
 * syscall, runs the BPF interpreter, but exits after 2 instructions.
 */
static int apply_trivial(void)
{
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {
        .len = sizeof(filter) / sizeof(filter[0]),
        .filter = filter,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
        perror("prctl(NO_NEW_PRIVS)");
        return -1;
    }
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
        perror("prctl(SECCOMP_FILTER) trivial");
        return -1;
    }
    return 0;
}

/*
 * Heavy filter: 204 instructions
 *   0:       Load architecture
 *   1:       Check arch matches → if wrong, jump to ALLOW (permissive)
 *   2:       Load syscall number
 *   3..202:  200 × JEQ against fake syscall numbers (10000..10199)
 *            None of these match real syscalls, so every check falls through.
 *   203:     Return ALLOW
 *
 * This simulates the overhead of Docker's default seccomp profile, which
 * checks each syscall against a ~300-entry allowlist. Every real syscall
 * traverses all 200 comparisons before reaching the final ALLOW.
 *
 * BPF jump encoding: for JEQ at position p,
 *   jt = offset to ALLOW (position 203) = 203 - p - 1
 *   jf = 0 (fall through to next check)
 *
 * Max jump offset = 200 (for position 3), fits in uint8_t (max 255).
 */
#define NUM_CHECKS 200
#define HEAVY_LEN  (3 + NUM_CHECKS + 1)  /* load_arch + check_arch + load_nr + checks + allow */

static int apply_heavy(void)
{
    struct sock_filter filter[HEAVY_LEN];
    int i = 0;

    /* 0: Load architecture */
    filter[i++] = (struct sock_filter)
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch));

    /* 1: Check architecture — if wrong, jump to ALLOW at end (permissive) */
    /*    jt=0 (correct arch: continue), jf=HEAVY_LEN-3 (jump to allow) */
    filter[i++] = (struct sock_filter)
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                 AUDIT_ARCH_CURRENT,
                 0,                /* match: continue to next instruction */
                 HEAVY_LEN - 3);   /* no match: jump to ALLOW */

    /* 2: Load syscall number */
    filter[i++] = (struct sock_filter)
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr));

    /* 3..202: 200 fake checks — none match real syscalls */
    for (int j = 0; j < NUM_CHECKS; j++) {
        int pos = 3 + j;
        int allow_pos = HEAVY_LEN - 1;  /* position 203 */
        int jt = allow_pos - pos - 1;    /* jump to ALLOW on match */
        filter[i++] = (struct sock_filter)
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                     10000 + j,   /* fake syscall number */
                     jt,          /* match: jump to ALLOW (never taken) */
                     0);          /* no match: fall through (always) */
    }

    /* 203: Default ALLOW */
    filter[i++] = (struct sock_filter)
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

    struct sock_fprog prog = {
        .len = HEAVY_LEN,
        .filter = filter,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
        perror("prctl(NO_NEW_PRIVS)");
        return -1;
    }
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
        perror("prctl(SECCOMP_FILTER) heavy");
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
                "Usage: %s <trivial|heavy> <program> [args...]\n"
                "\n"
                "Apply a seccomp-bpf filter then exec <program>.\n"
                "  trivial  2-instruction allow-all (minimal overhead)\n"
                "  heavy    204-instruction filter (simulates Docker profile)\n",
                argv[0]);
        return 1;
    }

    const char *mode = argv[1];
    int rc;

    if (strcmp(mode, "trivial") == 0) {
        rc = apply_trivial();
    } else if (strcmp(mode, "heavy") == 0) {
        rc = apply_heavy();
    } else {
        fprintf(stderr, "Unknown mode '%s' (use 'trivial' or 'heavy')\n", mode);
        return 1;
    }

    if (rc != 0) {
        fprintf(stderr, "Failed to apply seccomp filter\n");
        return 1;
    }

    fprintf(stderr, "[seccomp_wrapper] Applied '%s' filter, exec'ing %s\n",
            mode, argv[2]);

    execvp(argv[2], argv + 2);
    perror("execvp");
    return 1;
}
