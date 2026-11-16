===================
System architecture
===================

Ventium is organized in two synthesizable layers targeting the **RK-XCZU15EG-F**
(``xczu15eg-ffvb1156-2-i``, AMD Vivado **2025.2**, board-qualified image
``c0e3fe43``, ``161`` defines, ``40.264133 MHz`` post-route slow-corner STA
sign-off):

1. **The P5/P54C Processor Subsystem** (``ventium_top`` + ``ventium_l1_axi``,
   listed in ``rtl_ven_core.f``) — the 5-stage in-order dual-issue U+V integer
   core (``core.sv`` + ``core_*.svh``), the shared pipelined 80-bit x87 FPU
   (``fp_shared/``), split **8 KiB 2-way L1 instruction and 8-bank L1 data
   caches** (with **no enabled L2**), **32-entry 4-way I-TLB** and **64-entry
   4-way D-TLB**, dual-ported **256-entry 4-way BTB**, and 64-bit AXI4 master
   (plus the standalone SVA-verified 64-bit P5 pin-level BIU ``biu_p5.sv``).
2. **The PC/AT Platform & ZynqMP Bridge** (``rtl_ven_soc.f`` + ``fpga/``) —
   ``ven_ao486_shim`` and ``ven_axi2avalon`` adapt the Ventium CPU in place of
   the 486 inside the MiSTer PC/AT chipset (``3rd-party/ao486_MiSTer``), while
   ``ven_ddram_axi_posted`` provides a **16-slot posted DDR4 write queue** with
   CAM read-after-write bypass and an architectural external-drain barrier into
   ZynqMP ``S_AXI_HP0_FPD`` (``0x6000_0000`` ``no-map`` DDR4), paired with
   runtime MMCM DRP clock synthesis (``ven_pll_ctrl``) and a 64 KiB AXI-Lite
   management/debug/PMU aperture at ``0xA000_0000`` (``ven_mgmt_axil`` +
   ``ven_soc_dbg``).

On physical hardware in mandatory ``U/V + system fast-pipe`` mode
(``cycle_mode=1``), image ``c0e3fe43`` passes both standard CoreMark seeds,
cold Windows 95 OSR2 GUI + shutdown, and cold DOS Quake ``timedemo demo1``
(``8.0 FPS``, ``969`` frames / ``121.2 s`` at ``39.999802 MHz``), retiring
**0.515778001 total U+V instructions per cycle** (``0.397847833``
primary/U-only IPC, including ``REP``-element retirement, across interior
gameplay cycles ``28,696,827,616–32,989,404,795``; prior ``2886d24c`` baseline
``0.496499864`` / ``0.383002768``).

The core microarchitecture
==========================

The core implements the Pentium **five-stage, in-order, dual-issue** pipeline
(``PF`` → ``D1`` → ``D2`` → ``EX`` → ``WB``). Each block in the diagram below
names the SystemVerilog module(s) that implement it in ``rtl/`` and
``fp_shared/``:

.. graphviz:: diagrams/ventium-core.dot

* **PF — Front End & Branch Prediction.** The split **8 KiB L1 I-Cache**
  (``icache.sv``, 128 sets × 2 ways × 32 B lines, ``8`` RAMB36 data arrays +
  LUTRAM tags under ``VEN_IC_BRAM``, physical snoop invalidation tags
  ``ic_ptag``, fanout-replicated ``pf_fill_addr_rep[0..3]``, and narrow 32-byte
  ``ic_res_line_base`` selection) pairs with a **32-entry 4-way I-TLB**
  (``tlb_assoc.sv``, ``VEN_ITLB_ASSOC_4WAY``), resident front-end page filter
  (``VEN_FE_PIPE``), instruction-length predecoder (``ven_predecode_len.sv``),
  and dual-ported **256-entry 4-way BTB** (``bpred_btb.sv``, 2-bit bimodal
  saturating counters + **4-entry RAS** supporting simultaneous fetch lookup
  and retire update).
* **D1 — Decode & AP-500 Pairing.** Dual fast-path instruction decoders
  (``decode.sv``) crack variable-length x86 instructions into ``fpd_t`` records
  for ``S_PIPE``, while ``decode_stages.sv`` handles general prefix, ModR/M,
  SIB, system, and multi-cycle x87 forms. ``issue_uv.sv`` enforces Intel AP-500
  dual-issue pairing rules (``UV`` / ``PU`` / ``PV`` / ``NP`` classes, RAW/WAW
  interlocks, ``ESP`` stack and U→V flag-forwarding special pairs; see
  :doc:`Instruction Catalog <isa/index>`).
* **D2 — Register File & Dual AGUs.** ``regfile.sv`` provides the multi-port
  32-bit GPR file (with sub-register byte/word merging and EX/WB forwarding),
  and ``ven_p54_dual_agu.sv`` computes parallel U and V effective addresses
  with 1-cycle AGI interlock detection and canonical segment-relocation
  translation.
* **EX & WB — Superscalar U+V Execution, Fast-Path S_PIPE & Microsequencer.**
  ``u_pipe.sv`` (full ALU + barrel shifter + carry chain), ``v_pipe.sv``
  (ALU + branch resolution), and ``uv_common.sv`` execute paired integer uops in
  a single cycle. In protected/paged mode, ``S_PIPE`` (``core_fastpath.svh``)
  sustains 1-cycle flat, relocated, and bounded load/store fast paths
  (``MOV``, ``ALU``, ``PUSH``/``POP``, ``LEA``, ``MOVZX``/``MOVSX``), alongside
  pipelined ``REP STOS``/``REP MOVS`` cacheable streaming
  (``VEN_REP_STOS_STREAM``) and the iterative radix-2 integer divider
  (``ven_idiv.sv``). Cross-page accesses are owned by the split-page fragment
  engine (using untranslated ``cur_lin_nat``, probe-before-write safety, and
  ``S_WALK`` shaping freeze), backed by a hardware 2-level 4 KiB / 4 MiB page
  walker, 32-bit hardware task switching, SMM, and precise x86 fault restart.
* **Shared Pipelined x87 FPU (fp_shared/).** Under ``VEN_FP_SHARED``,
  ``ven_fp_top.sv`` owns the pointer-mapped 8×80-bit ``floatx80`` stack
  (``ven_fp_state.sv``) with a **zero-cycle FXCH rename queue**
  (``ven_fp_fxch_queue.sv``), 2-stage pipelined ``FADD``/``FSUB``/``FMUL``
  (``ven_fp_alu.sv``, :doc:`microarch/fp-commit-pipeline`), 38-DSP shared wide
  multiplier & table-driven polynomial transcendental engine
  (``ven_fp_widemul.sv``, ``ven_fp_estdiv.sv``, ``ven_fp_trans.sv`` covering
  ``F2XM1``, ``FYL2X``, ``FYL2XP1``, ``FSIN``, ``FCOS``, ``FSINCOS``, ``FPTAN``,
  ``FPATAN``), unified radix-4 SRT divider/sqrt/``FPREM``/``FPREM1``
  (``fpu_srt_div.sv``, :doc:`microarch/srt-divider`), and iterative packed-BCD
  converters (``ven_bcd.sv``, ``ven_bcd_to_fp.sv``) in ``72,204`` LUTs.
* **L1 Data Cache, D-TLB & AXI4 Subsystem (ventium_l1_axi).** A **64-entry
  4-way D-TLB** (``tlb_assoc.sv``, ``VEN_DTLB_ASSOC_4WAY``) + front-end D-TLB
  slice feed the **8 KiB 2-way L1 D-Cache** (``ven_l1d.sv``, 128 sets × 32 B
  lines, **8-way 32-bit word-interleaved banks** via ``ven_p54_bank_arb.sv``
  and ``ven_p54_hit_return.sv`` for dual-port U+V read hits, write-back /
  write-allocate cached policy, ``ven_cachemap.sv`` PAM/TOM classification, and
  byte-exact narrow UC I/O & MMIO). The deployed profile uses **full P5 8 KiB
  L1s and no enabled L2**, driving ``ven_axi_master.sv`` (64-bit AXI4).
  (``dcache_timing.sv`` and direct-mapped ``tlb.sv`` remain only for standalone
  non-``VEN_L1_AXI`` unit testbenches; ``biu_p5.sv`` provides the pin-level
  64-bit P5 external bus model verified by ``make bus bus-sva``.)

The RK-XCZU15EG-F PC/AT platform
================================

In both full-PC simulation (``ao486-sim/``) and deployed Zynq UltraScale+
hardware (``fpga/``), Ventium replaces the 486 CPU inside the MiSTer PC/AT
motherboard (``rtl_ven_soc.f``):

.. graphviz:: diagrams/ventium-soc.dot

* **CPU-to-Platform Shim & Chipset (ven_ao486_shim.sv, ven_axi2avalon.sv).**
  Bridges CPU port I/O, VGA planar/linear MMIO, A20 masking, and ``INTR``/``INTA``
  interrupt cycles into ``3rd-party/ao486_MiSTer/rtl/system.v``: cascaded
  ``8259A`` PICs, ``8254`` PIT, dual ``8237`` DMA, ``MC146818`` RTC/CMOS,
  ``8042`` PS/2 keyboard & mouse (with hardware injection mailboxes
  ``ven_ps2_mailbox.sv`` / ``ven_ps2_device.sv``), primary/secondary IDE and
  floppy, full VGA + 128-RAMB36 passive frame capture (``ven_video_capture.sv``),
  and Sound Blaster 16 + OPL3 audio (outer ``ao486`` L2 wrapper bypassed).
* **16-Slot Posted DDR4 Bridge & External Drain Barrier (ven_ddram_axi_posted.sv).**
  Buffers cache writebacks and memory writes in a 16-entry posted queue with
  **CAM read-after-write hazard bypass** before crossing ``128b @ 100 MHz`` into
  ZynqMP ``S_AXI_HP0_FPD`` (``0x6000_0000–0x6FFF_FFFF`` ``no-map`` DDR4).
  Because posted acknowledgement is not external DDR4 completion, hardware
  enforces a true external-drain/fault barrier before ``IN``/``OUT`` port I/O,
  debug halt, and runtime clock switches.
* **Runtime MMCM DRP Clocking & 0xA000_0000 Debug/PMU Aperture.**
  ``ven_pll_ctrl.sv`` / ``ven_programmable_clock.v`` reprogram a single
  ``MMCME4_ADV`` (``100 MHz * 10 / N``, boot ``N = 25`` → ``40.000 MHz``) via
  XAPP888 DRP over EMIO GPIO while holding guest reset after DDR drain.
  ``ven_mgmt_axil.v`` + ``ven_soc_dbg.sv`` map BIOS/IDE/FDD sector backing,
  ``primary/U`` and ``total U+V`` 64-bit retirement counters, forensic freeze
  snapshots, quiescent boundary halt/step/breakpoint controls, and AXI
  read/write profilers into the 64 KiB ``M_AXI_HPM0_FPD`` aperture at
  ``0xA000_0000`` (see :doc:`soc/theory-of-operation` and
  :doc:`debug-instrumentation`).

.. note::

   Earlier bring-up milestones used a minimal standalone ``ventium_soc``
   wrapper and KV260 PS-assisted peripheral C models (documented as historical
   architecture in :doc:`soc/theory-of-operation` and
   :doc:`soc/peripheral-split`). All current physical FPGA builds and full-PC
   simulations use the full-RTL MiSTer PC/AT + ``ven_ddram_axi_posted``
   platform above.
