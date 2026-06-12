// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_soc_regs.h — the ven_soc_axil AXI-Lite register map, as seen
// by the PS A53 over M_AXI_HPM0_FPD. MUST stay in lock-step with rtl/soc/ven_soc_axil.sv.
// The slave is mapped at HPM0_BASE (0xA000_0000, fpga/scripts/bd_kv260_soc.tcl); the
// DDR carveout (program image + Quake framebuffer) is at CARVEOUT_BASE (0x4000_0000).

#ifndef VEN_SOC_REGS_H
#define VEN_SOC_REGS_H

#include <stdint.h>

#define VEN_HPM0_BASE     0xA0000000UL   // AXI-Lite control slave aperture
#define VEN_HPM0_SIZE     0x00010000UL   // 64 KiB
#define VEN_CARVEOUT_BASE 0x40000000UL   // reserved DDR carveout (== REMAP_BASE)
#define VEN_CARVEOUT_SIZE 0x10000000UL   // 256 MiB

// ---- register offsets (byte addresses) ------------------------------------
#define VEN_R_CTRL       0x00   // RW
#define VEN_R_STATUS     0x04   // RO
#define VEN_R_INIT_EIP   0x08   // RW
#define VEN_R_INIT_ESP   0x0C   // RW
#define VEN_R_MODE       0x10   // RW
#define VEN_R_RETIRE_LO  0x14   // RO (snapshots HI on read)
#define VEN_R_RETIRE_HI  0x18   // RO
#define VEN_R_IO_STATUS  0x20   // RO
#define VEN_R_IO_ADDR    0x24   // RO
#define VEN_R_IO_SIZE    0x28   // RO
#define VEN_R_IO_WDATA   0x2C   // RO
#define VEN_R_IO_RDATA   0x30   // RW (PS writes the IN return value)
#define VEN_R_IO_CTRL    0x34   // W1P: [0]ACK [1]IRQ_CLR
#define VEN_R_INTR       0x38   // RW: PS->core interrupt-injection seam (F3)
#define VEN_R_IRQ_STAT   0x70   // R/W1C: [0]io [1]inta-seen
#define VEN_R_IDENT      0x7C   // RO == 0x5654_4D43 "VTMC"

// ---- CTRL bits ------------------------------------------------------------
#define VEN_CTRL_CORE_RUN   (1u << 0)   // 1 = release the core's reset
#define VEN_CTRL_FLUSH_REQ  (1u << 1)   // W1P: pulse flush_all (mode-2 L1 invalidate)
#define VEN_CTRL_RST_REQ    (1u << 2)   // W1P: drop CORE_RUN (re-assert reset)
#define VEN_CTRL_IRQ_EN     (1u << 8)   // 1 = irq_out drives pl_ps_irq0

// ---- STATUS bits ----------------------------------------------------------
#define VEN_ST_CPU_HUNG     (1u << 0)
#define VEN_ST_BUS_ERR      (1u << 1)
#define VEN_ST_IN_RESET     (1u << 2)
#define VEN_ST_IO_REQ       (1u << 8)   // an IN/OUT is pending
#define VEN_ST_SYS_PEND     (1u << 9)   // an int-0x80 is pending (F4 / +VEN_PS_PROXY)

// ---- MODE bits ------------------------------------------------------------
#define VEN_MODE_BOOT_SYS   (1u << 0)   // boot_mode: 1 = system (F000:FFF0), 0 = user
#define VEN_MODE_CYCLE      (1u << 1)   // cycle_mode (dual issue)
#define VEN_MODE_BUS        (1u << 2)   // bus_mode (biu) — keep 0 (mode 2 supersedes)
#define VEN_MODE_L1AXI      (1u << 3)   // l1axi_en: 1 = route memory via L1/AXI to DDR
#define VEN_MODE_PROXY      (1u << 4)   // proxy_en: 1 = int-0x80 proxy (F4 only)
#define VEN_MODE_COSIM      (1u << 5)   // cosim_en: 1 = route IN/OUT to the io bridge
#define VEN_MODE_SOCEN      (1u << 6)   // soc_en: 1 = ungate the core's external-INTR
                                        //   divert (F3; also selects the SoC CPUID arm)
#define VEN_MODE_ERRATA_SH  8           // errata_en[4:0] at bits [12:8]

// ---- INTR bits (R_INTR, the F3 PS->core interrupt-injection seam) ----------
// The PS-side 8259 C model (sw/ps_periph/ven_pic.c) drives this register as its
// INT/INTA wire pair: write {ASSERT | vector} to raise the core's intr level with
// the staged vector; the core's 1-clock inta strobe (taken at S_DECODE/S_HLTWAIT
// when IF=1) clears ASSERT in hardware and sets INTA_SEEN (sticky, W1C). On seeing
// INTA_SEEN the PS calls its PIC model's intack (ISR set / IRR clear), clears the
// bit, and stages the next vector (or leaves the level down). Requires MODE_SOCEN.
#define VEN_INTR_VEC_MASK   0xFFu       // [7:0] staged vector (latched on inta)
#define VEN_INTR_ASSERT     (1u << 8)   // level on the core's intr pin
#define VEN_INTR_INTA_SEEN  (1u << 9)   // R: core pulsed inta; W1C
#define VEN_INTR_IRQ_EN     (1u << 16)  // 1 = INTA_SEEN also raises irq_out (GIC)

// ---- IRQ_STAT bits ----------------------------------------------------------
#define VEN_IRQSTAT_IO      (1u << 0)   // io-bridge request latch (W1C)
#define VEN_IRQSTAT_INTA    (1u << 1)   // inta-seen latch (W1C, alias of R_INTR[9])

// ---- IO_STATUS bits -------------------------------------------------------
#define VEN_IO_PENDING      (1u << 0)
#define VEN_IO_IS_WRITE     (1u << 1)   // 1 = OUT, 0 = IN
#define VEN_IO_BUSY         (1u << 2)

// ---- IO_CTRL bits ---------------------------------------------------------
#define VEN_IO_ACK          (1u << 0)   // commit IO_RDATA + pulse io_ack (release core)
#define VEN_IO_IRQ_CLR      (1u << 1)   // clear the interrupt latch

#define VEN_IDENT_MAGIC     0x56544D43u

#endif // VEN_SOC_REGS_H
