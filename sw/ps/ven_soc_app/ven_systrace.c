// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_systrace.c — see ven_systrace.h. PS-side observability for
// the F4 int-0x80 Quake proxy: a decoded last-N syscall ring, a per-NR histogram,
// a no-progress watchdog, a same-syscall livelock detector, a frame/first-frame
// heartbeat, a live stdout tee, and a SIGUSR1 snapshot. All bookkeeping over data
// the --quake service loop already has; no edits to the shared verif/tb sources.

#define _GNU_SOURCE 1
#include "ven_systrace.h"
#include "ven_quake.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RING_DEPTH 128
#define HIST_SIZE  512          // i386 NRs go up to 406; 512 covers them

typedef struct {
    uint32_t nr;
    uint32_t args[6];           // {ebx,ecx,edx,esi,edi,ebp}
    uint32_t eax;
    uint64_t idx;               // syscall index
    uint64_t cyc;               // synthetic-clock cycle count
    int      fail;              // eax in the -errno band
    char     note[56];          // decoded summary (path / fd / len / ...)
} sysent_t;

// ---- config (read once) ----
static int      g_ring_en = 0;
static int      g_tee_en  = 0;
static int      g_commit_verify = 0;
static long     g_timeout_ms = 0;          // 0 = watchdog off
static uint64_t g_livelock_n = 0;          // 0 = off
static uint64_t g_video_stall_k = 50000;

// ---- ring + histogram ----
static sysent_t g_ring[RING_DEPTH];
static uint64_t g_ring_count = 0;          // total recorded (head = (count-1)%DEPTH)
static struct { uint64_t count, fail; uint32_t last_eax; } g_hist[HIST_SIZE];

// ---- livelock ----
static uint32_t g_prev_nr = 0xFFFFFFFFu;
static uint32_t g_prev_args[6];
static uint32_t g_prev_eax = 0;
static uint64_t g_repeat = 0;

// ---- watchdog ----
static int      g_wd_init = 0;
static long     g_last_progress_ms = 0;
static uint64_t g_wd_prev_sys = 0, g_wd_prev_ret = 0;

// ---- heartbeat / first-frame ----
static int      g_first_frame_seen = 0;
static uint64_t g_hb_prev_video = 0, g_hb_prev_sys = 0;
static long     g_hb_prev_ms = 0;
static uint64_t g_video_flat_sys = 0;
static int      g_video_stall_warned = 0;

// ---- stdout tee cursor ----
static uint64_t g_tee_cursor = 0;

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int is_fail(uint32_t eax) {
    int32_t e = (int32_t)eax;
    return e < 0 && e >= -4095;            // the -errno band
}

void systrace_init(void) {
    g_ring_en       = getenv("VEN_SYS_RING")      ? 1 : 0;
    g_tee_en        = getenv("VEN_QUAKE_LIVE_TTY") ? 1 : 0;
    g_commit_verify = getenv("SYS_COMMIT_VERIFY") ? 1 : 0;
    int dbg         = getenv("VEN_DBG")           ? 1 : 0;

    const char* t = getenv("SYS_TIMEOUT_MS");
    g_timeout_ms = t ? atol(t) : ((g_ring_en || dbg) ? 2000 : 0);   // conservative default
    const char* l = getenv("SYS_LIVELOCK_N");
    g_livelock_n = l ? strtoull(l, 0, 0) : 2000;
    const char* k = getenv("SYS_VIDEO_STALL_K");
    if (k) g_video_stall_k = strtoull(k, 0, 0);

    g_last_progress_ms = g_hb_prev_ms = now_ms();
    if (g_ring_en || g_tee_en || g_timeout_ms || g_commit_verify)
        fprintf(stderr, "ven_systrace: ring=%d tee=%d watchdog=%ldms livelock=%llu commit_verify=%d\n",
                g_ring_en, g_tee_en, g_timeout_ms, (unsigned long long)g_livelock_n, g_commit_verify);
}

// decode the human-meaningful args for high-value NRs into e->note.
static void build_note(sysent_t* e) {
    const uint32_t* a = e->args;
    e->note[0] = '\0';
    switch (e->nr) {
    case 5: {  // open(path=ebx)
        char p[40]; ven_quake_read_cstr(a[0], p, (int)sizeof(p));
        snprintf(e->note, sizeof(e->note), "\"%s\"", p);
        break;
    }
    case 295: {  // openat(path=ecx)
        char p[40]; ven_quake_read_cstr(a[1], p, (int)sizeof(p));
        snprintf(e->note, sizeof(e->note), "\"%s\"", p);
        break;
    }
    case 192:  // mmap2(len=ecx, prot=edx, flags=esi, fd=edi)
        snprintf(e->note, sizeof(e->note), "len=%u fl=0x%x fd=%d", a[1], a[3], (int)(int32_t)a[4]);
        break;
    case 3: case 145:   // read/readv(fd=ebx, cnt=edx)
    case 4: case 146:   // write/writev(fd=ebx, cnt=edx)
        snprintf(e->note, sizeof(e->note), "fd=%u cnt=%u", a[0], a[2]);
        break;
    case 19: case 140:  // lseek/_llseek(fd=ebx)
    case 6:             // close(fd=ebx)
        snprintf(e->note, sizeof(e->note), "fd=%u", a[0]);
        break;
    case 45:            // brk(addr=ebx)
        snprintf(e->note, sizeof(e->note), "0x%x", a[0]);
        break;
    default:
        break;
    }
}

int systrace_record(uint32_t nr, const uint32_t args[6], uint32_t eax, int unsupported,
                    uint64_t idx, uint64_t cyc) {
    int flags = 0;
    (void)unsupported;

    // livelock detection is cheap and useful even without the full ring.
    if (g_livelock_n) {
        int same = (nr == g_prev_nr) && (eax == g_prev_eax) &&
                   (memcmp(args, g_prev_args, sizeof(g_prev_args)) == 0);
        if (same) { if (++g_repeat >= g_livelock_n) flags |= SYSTRACE_LIVELOCK; }
        else {
            g_repeat = 0; g_prev_nr = nr; g_prev_eax = eax;
            memcpy(g_prev_args, args, sizeof(g_prev_args));
        }
    }

    if (g_ring_en) {
        if (nr < HIST_SIZE) {
            g_hist[nr].count++;
            if (is_fail(eax)) g_hist[nr].fail++;
            g_hist[nr].last_eax = eax;
        }
        sysent_t* e = &g_ring[g_ring_count % RING_DEPTH];
        e->nr = nr; e->eax = eax; e->idx = idx; e->cyc = cyc; e->fail = is_fail(eax);
        memcpy(e->args, args, sizeof(e->args));
        build_note(e);
        g_ring_count++;
    }
    return flags;
}

int systrace_watchdog_enabled(void) { return g_timeout_ms > 0; }

int systrace_watchdog(uint64_t syscalls, uint64_t retire, int sys_pend) {
    if (g_timeout_ms <= 0) return 0;
    long now = now_ms();
    if (!g_wd_init) {
        g_wd_init = 1; g_wd_prev_sys = syscalls; g_wd_prev_ret = retire;
        g_last_progress_ms = now; return 0;
    }
    if (syscalls != g_wd_prev_sys || retire != g_wd_prev_ret) {
        g_wd_prev_sys = syscalls; g_wd_prev_ret = retire; g_last_progress_ms = now;
        return 0;
    }
    if (now - g_last_progress_ms > g_timeout_ms) {
        fprintf(stderr,
                "\nven_systrace: WATCHDOG no progress for %ldms (syscalls=%llu retire=%llu SYS_PEND=%d)\n",
                now - g_last_progress_ms, (unsigned long long)syscalls,
                (unsigned long long)retire, sys_pend);
        g_last_progress_ms = now;     // re-arm (so a post-dump re-check doesn't spam)
        return 1;
    }
    return 0;
}

int systrace_commit_verify_enabled(void) { return g_commit_verify; }

const char* systrace_heartbeat(uint64_t video_bytes, uint64_t syscalls) {
    static char buf[160];
    long now = now_ms();
    long dt = now - g_hb_prev_ms; if (dt <= 0) dt = 1;
    uint64_t dvid = video_bytes - g_hb_prev_video;
    uint64_t dsys = syscalls    - g_hb_prev_sys;
    double rate = (double)dsys * 1000.0 / (double)dt;
    snprintf(buf, sizeof(buf), " vid=%llu(+%llu) sys=%llu rate=%.0f/s",
             (unsigned long long)video_bytes, (unsigned long long)dvid,
             (unsigned long long)syscalls, rate);

    if (!g_first_frame_seen && video_bytes > 0) {
        g_first_frame_seen = 1;
        fprintf(stderr, "\n*** ven_systrace: FIRST P5Q1 bytes at syscall #%llu (t=%ldms) ***\n",
                (unsigned long long)syscalls, now);
    }
    if (dvid == 0 && dsys > 0) g_video_flat_sys += dsys; else g_video_flat_sys = 0;
    if (g_first_frame_seen && !g_video_stall_warned && g_video_stall_k &&
        g_video_flat_sys > g_video_stall_k) {
        g_video_stall_warned = 1;
        fprintf(stderr, "ven_systrace: video stalled (no new frame in %llu syscalls; "
                        "renderer hung, kernel still live)\n", (unsigned long long)g_video_flat_sys);
    }
    g_hb_prev_ms = now; g_hb_prev_video = video_bytes; g_hb_prev_sys = syscalls;
    return buf;
}

void systrace_tee_stdout(void) {
    if (!g_tee_en) return;
    uint64_t len = ven_quake_stdout_len();
    char b[256];
    while (g_tee_cursor < len) {
        int n = ven_quake_stdout_copy(g_tee_cursor, b, (int)sizeof(b));
        if (n <= 0) break;
        fwrite(b, 1, (size_t)n, stderr);
        g_tee_cursor += (uint64_t)n;
    }
    fflush(stderr);
}

void systrace_dump(const char* reason) {
    if (!g_ring_en) return;
    fprintf(stderr, "\n=== ven_systrace dump (%s) — %llu syscalls recorded ===\n",
            reason ? reason : "?", (unsigned long long)g_ring_count);

    uint64_t n = g_ring_count < RING_DEPTH ? g_ring_count : RING_DEPTH;
    fprintf(stderr, " syscall ring (newest first, %llu of %d):\n", (unsigned long long)n, RING_DEPTH);
    for (uint64_t i = 0; i < n; i++) {
        uint64_t slot = (g_ring_count - 1 - i) % RING_DEPTH;
        sysent_t* e = &g_ring[slot];
        fprintf(stderr, "  [-%2llu] #%llu %-16s eax=0x%08x%s %s\n",
                (unsigned long long)i, (unsigned long long)e->idx,
                ven_quake_nr_name(e->nr), e->eax, e->fail ? " FAIL" : "", e->note);
    }

    fprintf(stderr, " syscall histogram (busiest):\n");
    static int used[HIST_SIZE];
    memset(used, 0, sizeof(used));
    int printed = 0;
    for (int rank = 0; rank < 15; rank++) {
        uint64_t best = 0; int bi = -1;
        for (int kk = 0; kk < HIST_SIZE; kk++)
            if (!used[kk] && g_hist[kk].count > best) { best = g_hist[kk].count; bi = kk; }
        if (bi < 0) break;
        used[bi] = 1; printed++;
        fprintf(stderr, "   %-16s %6llu calls  %llu fail  last=0x%08x\n",
                ven_quake_nr_name((uint32_t)bi), (unsigned long long)g_hist[bi].count,
                (unsigned long long)g_hist[bi].fail, g_hist[bi].last_eax);
    }
    if (!printed) fprintf(stderr, "   (no syscalls recorded)\n");
    fflush(stderr);
}

void systrace_snapshot(void) {
    uint64_t sys = ven_quake_syscalls();
    uint64_t vid = ven_quake_video_total();
    fprintf(stderr, "\n=== ven_systrace SNAPSHOT (live, non-exiting) ===\n");
    fprintf(stderr, " syscalls=%llu video_bytes=%llu first_frame=%d\n",
            (unsigned long long)sys, (unsigned long long)vid, g_first_frame_seen);
    if (g_ring_en && g_ring_count) {
        sysent_t* e = &g_ring[(g_ring_count - 1) % RING_DEPTH];
        fprintf(stderr, " last syscall: #%llu %s eax=0x%08x%s %s\n",
                (unsigned long long)e->idx, ven_quake_nr_name(e->nr), e->eax,
                e->fail ? " FAIL" : "", e->note);
    }
    uint64_t slen = ven_quake_stdout_len();
    if (slen) {
        char b[257];
        uint64_t from = slen > 256 ? slen - 256 : 0;
        int nn = ven_quake_stdout_copy(from, b, 256);
        if (nn < 0) nn = 0;
        b[nn] = '\0';
        fprintf(stderr, " guest stdout tail: %s\n", b);
    }
    fprintf(stderr, "================================================\n");
    fflush(stderr);
}
