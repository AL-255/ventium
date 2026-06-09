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
#define VEN_R_IRQ_STAT   0x70   // R/W1C
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
#define VEN_MODE_ERRATA_SH  8           // errata_en[4:0] at bits [12:8]

// ---- IO_STATUS bits -------------------------------------------------------
#define VEN_IO_PENDING      (1u << 0)
#define VEN_IO_IS_WRITE     (1u << 1)   // 1 = OUT, 0 = IN
#define VEN_IO_BUSY         (1u << 2)

// ---- IO_CTRL bits ---------------------------------------------------------
#define VEN_IO_ACK          (1u << 0)   // commit IO_RDATA + pulse io_ack (release core)
#define VEN_IO_IRQ_CLR      (1u << 1)   // clear the interrupt latch

#define VEN_IDENT_MAGIC     0x56544D43u

#endif // VEN_SOC_REGS_H
