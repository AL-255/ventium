// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Quick end-to-end check of the libventium_viz C ABI.
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ventium_viz.h"

int main(int argc, char** argv) {
  char default_img[4096] = {0};
  const char* img = argc > 1 ? argv[1] : NULL;
  if (!img) {
    // Resolve from the verifier binary, not the caller's working directory.
    // build.sh places smoke_test beside this source/library.
    char executable[4096];
    ssize_t len = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
    if (len > 0) {
      executable[len] = '\0';
      char* slash = strrchr(executable, '/');
      if (slash) {
        *slash = '\0';
        static const char suffix[] =
          "/../../build/verify/mb_brloop.cycle.flat";
        size_t base_len = strlen(executable);
        if (base_len + sizeof(suffix) <= sizeof(default_img)) {
          memcpy(default_img, executable, base_len);
          memcpy(default_img + base_len, suffix, sizeof(suffix));
        }
      }
    }
    // Portable/caller-relative fallbacks keep an informative error possible
    // if /proc is unavailable.
    const char* fallbacks[] = {
      default_img,
      "build/verify/mb_brloop.cycle.flat",
      "../../build/verify/mb_brloop.cycle.flat",
      NULL
    };
    for (int i = 0; fallbacks[i]; ++i) {
      if (fallbacks[i][0] && access(fallbacks[i], R_OK) == 0) {
        img = fallbacks[i];
        break;
      }
    }
  }
  if (!img) {
    fprintf(stderr, "smoke_test: cannot locate mb_brloop.cycle.flat; "
                    "pass an image path explicitly\n");
    return 2;
  }
  uint32_t entry  = argc > 2 ? (uint32_t)strtoul(argv[2], 0, 0) : 0x08048000u;
  void* h = vv_create();
  long n = vv_load_image(h, img, entry);
  if (n <= 0) {
    fprintf(stderr, "smoke_test: failed to load %s (%ld)\n", img, n);
    vv_destroy(h);
    return 2;
  }
  printf("loaded %ld bytes from %s @ 0x%08x\n", n, img, entry);
  vv_reset(h, entry, 0x40c34910u, /*cycle_mode=*/1, /*system=*/0);

  uint64_t total = vv_step(h, 400, 0);
  vv_state_t s;
  vv_get_state(h, &s);
  printf("stepped %llu clocks; core_cyc=%u state=%s eip=0x%08x done=%d\n",
         (unsigned long long)total, s.core_cyc, vv_state_name(s.state), s.eip, vv_is_done(h));
  printf("retired=%llu  EAX=%08x ECX=%08x EDX=%08x EBX=%08x ESP=%08x\n",
         (unsigned long long)vv_retire_count(h),
         s.gpr[0], s.gpr[1], s.gpr[2], s.gpr[3], s.gpr[4]);
  printf("pipe_pair=%u stall=%u mispred=%u  ud_len=%u ud_simple=%u ud_is_branch=%u  ftop=%u fctrl=%04x\n",
         s.pipe_pair, s.stall_cnt, s.mispred_bubbles, s.ud_len, s.ud_simple, s.ud_is_branch,
         s.ftop, s.fctrl);

  static vv_cline_t lines[256];
  int ic = vv_get_icache(h, lines, 256);
  printf("icache valid lines: %d\n", ic);
  for (int i = 0; i < ic && i < 4; ++i)
    printf("  set=%3u way=%u tag=0x%05x lru=%u  b0..3=%02x %02x %02x %02x\n",
           lines[i].set, lines[i].way, lines[i].tag, lines[i].lru,
           lines[i].data[0], lines[i].data[1], lines[i].data[2], lines[i].data[3]);
  int dc = vv_get_dcache(h, lines, 256);
  printf("dcache valid lines: %d\n", dc);

  static vv_tlb_t tlb[16];
  vv_get_tlb(h, 0, tlb);
  int itlb_v = 0; for (int i = 0; i < 16; ++i) itlb_v += tlb[i].valid;
  printf("itlb valid entries: %d\n", itlb_v);

  static vv_retire_t rr[16];
  int got = vv_get_retires(h, 0, rr, 16);
  printf("first %d retires:\n", got);
  for (int i = 0; i < got; ++i)
    printf("  n=%llu cyc=%llu pc=0x%08x pipe=%u paired=%u bytes=%02x %02x %02x\n",
           (unsigned long long)rr[i].n, (unsigned long long)rr[i].cyc, rr[i].pc,
           rr[i].pipe, rr[i].paired, rr[i].bytes[0], rr[i].bytes[1], rr[i].bytes[2]);

  static vv_cycle_t cc[8];
  int gc = vv_get_cycles(h, 0, cc, 8);
  printf("first %d cycle samples:\n", gc);
  for (int i = 0; i < gc; ++i)
    printf("  cyc=%llu state=%s eip=0x%08x stall=%u retU=%u retV=%u\n",
           (unsigned long long)cc[i].cyc, vv_state_name(cc[i].state), cc[i].eip,
           cc[i].stall_cnt, cc[i].retU, cc[i].retV);

  int ok = total == 400 && s.core_cyc == 400
           && vv_retire_count(h) > 0 && ic > 0 && got > 0 && gc > 0;
  vv_destroy(h);
  if (!ok) {
    fprintf(stderr, "smoke_test: backend invariants failed\n");
    return 3;
  }
  puts("OK native C ABI smoke");
  return 0;
}
