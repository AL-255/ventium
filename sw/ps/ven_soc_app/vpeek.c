// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// vpeek — non-destructive reader of the KV260 DDR carveout, mapped EXACTLY like
// ven_soc_app (open /dev/mem O_RDWR|O_SYNC; mmap the whole 256 MB carveout at
// VEN_CARVEOUT_BASE, MAP_SHARED). busybox devmem maps a single page and (on this
// box) returns byte-lane-shifted/duplicated garbage for the carveout — so it is
// USELESS for reading guest memory; use this instead. Read-only + MAP_SHARED, so
// it is safe to run alongside a (halted) ven_soc_app --quake.
//
//   vpeek <guest_addr_hex> [n_words]      # folds addr & 0x0FFFFFFF into the carveout
//   vpeek 0x08048000 8                    # expect 464C457F 00010101 ... ("\x7fELF")
//   vpeek 0x40c34674 24                   # the guest stack at a halt
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define BASE 0x40000000UL      // VEN_CARVEOUT_BASE
#define SIZE 0x10000000UL      // VEN_CARVEOUT_SIZE (256 MiB)
#define MASK 0x0FFFFFFFu

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: vpeek <guest_addr> [n_words]\n"); return 2; }
    uint32_t g = (uint32_t)strtoul(argv[1], 0, 0);
    int n = (argc > 2) ? atoi(argv[2]) : 16;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    volatile uint8_t* d = mmap(0, SIZE, PROT_READ, MAP_SHARED, fd, BASE);
    if (d == MAP_FAILED) { perror("mmap"); return 1; }
    uint32_t off = g & MASK;
    for (int i = 0; i < n; i++) {
        uint32_t a = off + (uint32_t)i * 4u;
        uint32_t v = *(volatile uint32_t*)(d + a);
        // also show the 4 LE bytes so a byte-lane bug is unmistakable
        printf("%08x: %08x   %02x %02x %02x %02x\n",
               g + (uint32_t)i * 4u, v,
               v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff);
    }
    return 0;
}
