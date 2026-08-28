// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Build-only helper for the 2026-08-22 FPGA Quake recovery experiment.
//
// It preserves the production 64 KiB system BIOS, adds a 17-byte reset
// trampoline in a verified-zero tail slot, points the reset vector at it, and
// repairs the ROM's additive checksum.  The trampoline clears CR0.CD/NW and
// then far-jumps to the original F000:E05B entry.  This is a guest-binary
// workaround used to prove the rest of the FPGA/Quake path; it is not the RTL
// repair for the non-cacheable HP0 response-ownership defect.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    ROM_SIZE = 65536,
    STUB_OFF = 0xff60,
    CHECKSUM_OFF = 0xff80,
    RESET_OFF = 0xfff0,
};

static const uint8_t expected_reset[] = {0xea, 0x5b, 0xe0, 0x00, 0xf0};
static const uint8_t patched_reset[]  = {0xea, 0x60, 0xff, 0x00, 0xf0};
static const uint8_t stub[] = {
    0x0f, 0x20, 0xc0,                         // mov eax,cr0
    0x66, 0x25, 0xff, 0xff, 0xff, 0x9f,       // and eax,9fffffffh
    0x0f, 0x22, 0xc0,                         // mov cr0,eax
    0xea, 0x5b, 0xe0, 0x00, 0xf0,             // jmp far f000:e05b
};

static void die(const char *what)
{
    fprintf(stderr, "patch_boot0_cr0: %s: %s\n", what, strerror(errno));
    exit(1);
}

int main(int argc, char **argv)
{
    uint8_t rom[ROM_SIZE];
    unsigned sum = 0;

    if (argc != 3) {
        fprintf(stderr, "usage: %s INPUT_BOOT0.ROM OUTPUT_BOOT0.ROM\n", argv[0]);
        return 2;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) die("open input");
    if (fread(rom, 1, sizeof rom, in) != sizeof rom || fgetc(in) != EOF) {
        fprintf(stderr, "patch_boot0_cr0: input must be exactly 65536 bytes\n");
        return 1;
    }
    if (fclose(in)) die("close input");

    if (memcmp(rom + RESET_OFF, expected_reset, sizeof expected_reset)) {
        fprintf(stderr, "patch_boot0_cr0: unexpected reset vector; refusing to patch\n");
        return 1;
    }
    for (size_t i = 0; i < sizeof stub; ++i) {
        if (rom[STUB_OFF + i] != 0) {
            fprintf(stderr, "patch_boot0_cr0: stub slot is not empty at %04zx\n",
                    (size_t)STUB_OFF + i);
            return 1;
        }
    }
    if (rom[CHECKSUM_OFF] != 0) {
        fprintf(stderr, "patch_boot0_cr0: checksum byte slot is not empty\n");
        return 1;
    }

    memcpy(rom + STUB_OFF, stub, sizeof stub);
    memcpy(rom + RESET_OFF, patched_reset, sizeof patched_reset);

    for (size_t i = 0; i < sizeof rom; ++i) sum = (sum + rom[i]) & 0xffu;
    rom[CHECKSUM_OFF] = (uint8_t)(0u - sum);

    sum = 0;
    for (size_t i = 0; i < sizeof rom; ++i) sum = (sum + rom[i]) & 0xffu;
    if (sum != 0) {
        fprintf(stderr, "patch_boot0_cr0: internal checksum repair failed\n");
        return 1;
    }

    FILE *out = fopen(argv[2], "wb");
    if (!out) die("open output");
    if (fwrite(rom, 1, sizeof rom, out) != sizeof rom) die("write output");
    if (fclose(out)) die("close output");

    fprintf(stderr,
            "patch_boot0_cr0: wrote 65536-byte ROM, stub=F000:FF60, "
            "entry=F000:E05B, checksum[%04x]=%02x\n",
            CHECKSUM_OFF, rom[CHECKSUM_OFF]);
    return 0;
}
