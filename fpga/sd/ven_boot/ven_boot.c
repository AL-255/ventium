// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// fpga/sd/ven_boot/ven_boot.c — A53 BARE-METAL bring-up app for the KV260 Ventium SoC.
//
// This is the standalone (no-OS) analogue of sw/ps/ven_soc_app/ven_soc_app.c, packaged
// into BOOT.BIN so the board does something useful on the very first power-on, with
// nothing but a microSD card and a serial console attached (UART1 / MIO36-37, the KV260
// SOM console). PetaLinux is NOT required for this image.
//
// Boot chain: FSBL configures the PL with the Ventium bitstream, then loads + runs this
// ELF on A53 #0. It then drives the ven_soc_axil control slave (0xA000_0000) exactly as
// the cosim's tb_main / the Linux ven_soc_app do.
//
// It runs in TWO tiers so a partial bring-up still yields a definitive signal:
//   Tier 1 (always, certain-correct): read the IDENT register and confirm the magic.
//           This alone proves PL-configured + PS<->PL AXI-Lite alive + clocks running.
//   Tier 2 (best-effort): stage the F2 firmware (psocfw: COM1 banner) into the DDR
//           carveout, boot the core in real-mode (F000:FFF0), and service the port-I/O
//           bridge — routing COM1 (0x3F8) bytes to this console. Liveness is also shown
//           via the RETIRE instruction counter, independent of the io-bridge path.
//
// Register map + protocol: sw/ps/ven_soc_app/ven_soc_regs.h (lock-step with
// rtl/soc/ven_soc_axil.sv). Addresses come from that header so the two stay in sync.
//
// NOTE: like ven_soc_app.c, this is UNTESTED ON HARDWARE (no board in the dev loop). It
// implements the documented, gate-proven register protocol; Tier 1 is a plain AXI read
// of a constant and is correct by construction.

#include <stdint.h>
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"
#include "ven_soc_regs.h"

// psocfw_payload.h is generated at build time from verif/sys/tests/psocfw/psocfw.bin by
// build_sd_image.sh (xxd -i): `const unsigned char psocfw_bin[]; unsigned psocfw_bin_len;`.
#include "psocfw_payload.h"

// The F2 firmware is a 64 KiB -bios image occupying linear 0xF0000..0xFFFFF (reset vector
// at 0xFFFF0). In the L1/AXI carveout path the core's physical address A maps to DDR
// CARVEOUT_BASE+A, so the image loads at carveout offset 0xF0000 — identical to how the
// cosim maps a -bios image "so its last byte = 0xFFFFF".
#define PSOCFW_LOAD_OFF 0x000F0000u

static inline uint32_t reg_rd(uint32_t off)          { return Xil_In32(VEN_HPM0_BASE + off); }
static inline void     reg_wr(uint32_t off, uint32_t v){ Xil_Out32(VEN_HPM0_BASE + off, v); }

// --- port-I/O device emulation (mirror of ven_soc_app.c service_out/in) --------------
static int service_out(uint16_t port, uint32_t val) {
    switch (port) {
        case 0x00E9:                                 // bochs/qemu debug console
        case 0x03F8: outbyte((char)(val & 0xFF)); return 0;   // COM1 THR -> console
        case 0x00F4: return 1;                       // isa-debug-exit -> stop
        default:     return 0;                       // ignore unmodeled OUTs
    }
}
static uint32_t service_in(uint16_t port) {
    switch (port) {
        case 0x03FD: return 0x60;                    // COM1 LSR: THR-empty | TSR-empty
        case 0x03F8: return 0x00;                    // COM1 RBR: no input byte
        default:     return 0xFF;                    // unmodeled IN -> all-ones
    }
}

int main(void) {
    xil_printf("\r\n");
    xil_printf("=====================================================\r\n");
    xil_printf(" Ventium KV260 SoC — A53 bare-metal bring-up\r\n");
    xil_printf("=====================================================\r\n");

    // ---- Tier 1: IDENT smoke test (certain-correct) ---------------------------------
    uint32_t ident = reg_rd(VEN_R_IDENT);
    xil_printf("[ident] ctrl-slave @0x%08x  IDENT=0x%08x  (expect 0x%08x)\r\n",
               (unsigned)VEN_HPM0_BASE, (unsigned)ident, (unsigned)VEN_IDENT_MAGIC);
    if (ident != VEN_IDENT_MAGIC) {
        xil_printf("[ident] FAIL — slave not responding. PL not configured or AXI down.\r\n");
        xil_printf("        Halting. (Check boot-mode = SD, bitstream in BOOT.BIN.)\r\n");
        for (;;) { /* park */ }
    }
    xil_printf("[ident] OK — PL configured, PS<->PL AXI-Lite alive, clock running.\r\n");

    uint32_t st0 = reg_rd(VEN_R_STATUS);
    xil_printf("[ident] STATUS=0x%08x  in_reset=%d\r\n",
               (unsigned)st0, (int)!!(st0 & VEN_ST_IN_RESET));

    // ---- Tier 2: stage psocfw, boot the core, service the io-bridge -----------------
    xil_printf("[boot]  staging psocfw (%u bytes) -> carveout+0x%x ...\r\n",
               (unsigned)psocfw_bin_len, (unsigned)PSOCFW_LOAD_OFF);
    reg_wr(VEN_R_CTRL, 0);                            // ensure CORE_RUN=0 while staging
    volatile uint8_t *ddr = (volatile uint8_t *)(uintptr_t)(VEN_CARVEOUT_BASE + PSOCFW_LOAD_OFF);
    for (uint32_t i = 0; i < psocfw_bin_len; i++) ddr[i] = psocfw_bin[i];
    __asm__ volatile("dsb sy" ::: "memory");          // flush the image to DDR before run

    // boot config: real-mode reset (F000:FFF0), memory via L1/AXI, IN/OUT via io-bridge.
    reg_wr(VEN_R_INIT_EIP, 0x0000FFF0u);              // (ignored in boot-sys, set for clarity)
    reg_wr(VEN_R_INIT_ESP, 0x00007000u);
    reg_wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM | VEN_MODE_BOOT_SYS);
    xil_printf("[boot]  releasing core (MODE=L1AXI|COSIM|BOOT_SYS) ...\r\n");
    reg_wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);            // release reset -> run

    // service loop with a bounded idle watchdog so a wedged core can't hang the console.
    xil_printf("[boot]  --- core console (COM1) below ---\r\n");
    uint64_t serviced = 0;
    uint32_t idle = 0;
    const uint32_t IDLE_LIMIT = 200000000u;           // ~ a few seconds of polling
    for (;;) {
        uint32_t st = reg_rd(VEN_R_STATUS);
        if (st & VEN_ST_CPU_HUNG) {
            xil_printf("\r\n[boot]  CPU HUNG (bus_err=%d) after %u io ops\r\n",
                       (int)!!(st & VEN_ST_BUS_ERR), (unsigned)serviced);
            break;
        }
        if (st & VEN_ST_IO_REQ) {
            idle = 0;
            uint32_t ios  = reg_rd(VEN_R_IO_STATUS);
            uint16_t port = (uint16_t)reg_rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE) {
                uint32_t v = reg_rd(VEN_R_IO_WDATA);
                if (service_out(port, v)) {
                    reg_wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    xil_printf("\r\n[boot]  isa-debug-exit after %u io ops — clean stop\r\n",
                               (unsigned)serviced);
                    break;
                }
            } else {
                reg_wr(VEN_R_IO_RDATA, service_in(port));
            }
            reg_wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);  // release the stalled core
            serviced++;
        } else if (++idle >= IDLE_LIMIT) {
            uint32_t rl = reg_rd(VEN_R_RETIRE_LO);    // snapshots HI
            uint32_t rh = reg_rd(VEN_R_RETIRE_HI);
            xil_printf("\r\n[boot]  idle timeout — retired=%u:%08u io=%u (core alive=%d)\r\n",
                       (unsigned)rh, (unsigned)rl, (unsigned)serviced, (int)((rh|rl) != 0));
            break;
        }
    }

    uint32_t rl = reg_rd(VEN_R_RETIRE_LO);
    uint32_t rh = reg_rd(VEN_R_RETIRE_HI);
    xil_printf("[done]  retired=0x%08x%08x  serviced=%u io ops\r\n",
               (unsigned)rh, (unsigned)rl, (unsigned)serviced);
    xil_printf("[done]  Ventium bring-up complete. Parking A53.\r\n");
    for (;;) { /* park */ }
    return 0;
}
