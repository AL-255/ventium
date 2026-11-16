===================
Verilog Build Flags
===================

Ventium compiles from ordered SystemVerilog filelists (``rtl/ventium.f``,
``rtl_ven_core.f``, ``rtl_ven_soc.f`` — never wildcard globs) under two primary
configuration profiles:

1. **Zero-Define Differential Baseline** (``verif/tb``, ``make verify``):
   Compiles ``ventium_top`` with no optional ``+define+VEN_*`` flags, matching
   the pinned QEMU Pentium functional oracle and the ``p5trace`` M4/M5 cycle
   reference.
2. **Board-Qualified** ``c0e3fe43`` **Hardware Profile (161 Defines on** ``main`` **):**
   Hash-pinned in ``fpga/known_good_defines.txt`` and
   ``fpga/known_good_c0e3fe43.json`` for the **RK-XCZU15EG-F**
   (``xczu15eg-ffvb1156-2-i``, AMD Vivado **2025.2**, ``retime_muxf_route_first``).
   Closes slow-corner post-route static timing at **40.264133 MHz**
   (``WNS = +0.164 ns``, ``WHS = +0.010 ns``, ``0`` ``>=85%`` congestion
   hotspots) and passes the physical standard acceptance suite in mandatory
   ``U/V + system fast-pipe`` mode (``cycle_mode=1``) at **0.515778001 total
   U+V Quake gameplay IPC** (``0.397847833`` primary/U across cycles
   ``28,696,827,616–32,989,404,795``; prior ``2886d24c`` baseline ``0.496499864``
   / ``0.383002768``).

.. contents::
   :local:
   :depth: 2

Core, superscalar ``S_PIPE`` & Tier-1 IPC defines
=================================================

These defines enable protected-mode U+V fast-path execution, dual AGU pairing,
and Tier-1 IPC optimizations while preserving x86 segmentation, paging,
split-page fragment handling, and precise fault restart:

.. list-table::
   :header-rows: 1
   :widths: 30 14 56

   * - Define
     - In ``c0e3fe43``
     - Architectural / Datapath Effect
   * - ``VEN_SYS_FASTPATH``
     - **Yes**
     - Enables guarded ``S_PIPE`` dual-issue execution in 32-bit protected/paged
       mode; non-eligible forms fall back cleanly to the slow FSM.
   * - ``VEN_SYS_FASTPATH_RELOC``
     - **Yes**
     - Extends ``S_PIPE`` from flat base-zero segments to relocated protected-mode
       clients (e.g. DJGPP / CWSDPMI DOS Quake) via the canonical translatable
       address generator.
   * - ``VEN_SYS_FASTLOAD_FLAT`` / ``VEN_SYS_FASTLOAD_BOUNDED``
     - **Yes**
     - Enables 1-cycle ``S_PIPE`` memory loads under both full-limit flat
       segments and bounded non-zero-limit descriptors with full limit/D-TLB
       checks.
   * - ``VEN_SYS_FASTSTORE_FLAT`` / ``VEN_STORE_DISPATCH``
     - **Yes**
     - Admits within-page 32-bit stores directly through ``S_PIPE``; cross-page
       stores retain ``S_STORE`` probe-before-write fragment sequencing.
   * - ``VEN_SEG_ENFORCE``
     - **Yes**
     - Enforces per-access protected-mode segment limit, privilege, and
       code-extent checks across fast and slow paths.
   * - ``VEN_REP_STOS_STREAM``
     - **Yes**
     - Tier-1 IPC enhancement: streams cacheable ``REP STOSB/W/D`` stores at
       1 element/clock steady state with exact page, segment-limit, and
       interrupt-boundary termination.
   * - ``VEN_REP_MOVS_STREAM`` / ``_LOAD_FUSE`` / ``_CONT`` / ``VEN_REP_CONT_NO_UOP``
     - **Yes**
     - Pipelines ``REP MOVS`` cacheable copy iterations without re-decoding per
       element.
   * - ``VEN_FAST_MEM_ALU`` / ``_ADD`` / ``_ADD7`` / ``_ADC`` / ``_MOV7``
     - **Yes**
     - Enables ``S_PIPE`` memory-source ``ALU r, [mem]``, ``ADC r, [mem]``, and
       7-byte SIB/disp32 ``MOV``/``ADD`` forms.
   * - ``VEN_FAST_MEM_EXT``
     - Exp. branch
     - Admits 32-bit unprefixed ``0F B6/B7/BE/BF`` (``MOVZX``/``MOVSX`` memory
       loads up to 7 bytes) directly into ``S_PIPE`` as single-issue ``NP``
       loads (defined on ``experimental/uv-fast-ipc-apr``; post-freeze edits
       require separate qualification).
   * - ``VEN_FAST_BYTE_ALU`` / ``VEN_FAST_BYTE_SHIFT`` / ``VEN_FAST_BYTE_MEM_CMP``
     - **Yes**
     - Fast-paths 8-bit register ALU/shifts (including ``AH..BH`` parent-register
       merging) and byte memory ``CMP`` in ``S_PIPE``.
   * - ``VEN_FAST_UNARY_R`` / ``VEN_FAST_ROR_IMM`` / ``VEN_FAST_XCHG_R`` / ``VEN_FAST_MOFFS_STORE``
     - **Yes**
     - Fast-paths register ``NOT``/``NEG``, immediate ``ROR``/``ROL``, register
       ``XCHG``, and ``MOV [moffs], AL/EAX``.
   * - ``VEN_P54_DUAL_LOAD_PAIR`` / ``_DUAL_BYTE_LOAD_PAIR`` / ``_DUAL_STORE_PAIR`` / ``_LOAD_STORE_PAIR`` / ``_DUAL_READ_ALU_PAIR``
     - **Yes**
     - Enables P54C dual-AGU memory pairing across U and V slots when ``ven_l1d``
       banks do not conflict.
   * - ``VEN_P54_PREFIX66_REG`` / ``_PREFIX66_SYSTEM`` / ``_PREFIX_EX_CHAIN`` / ``_PREFIX_EX_SYSTEM`` / ``_PREFIX_AGI``
     - **Yes**
     - Handles ``0x66`` operand-size prefixes and prefix chains in ``S_PIPE``
       without slow-FSM fallback.
   * - ``VEN_PIPE_SDECODE`` / ``VEN_PIPE_SDISPATCH`` / ``_SDISPATCH_SHORT`` / ``VEN_PIPE_MEM_CHAIN`` / ``VEN_PIPE_REG_LOAD_PRIME``
     - **Yes**
     - Eliminates transition bubbles between ``S_DECODE`` and ``S_PIPE`` and
       primes back-to-back load/ALU chains (paired with ``VEN_RAW_*_PRIME``,
       ``VEN_REF_OPERAND_PRIME``, ``VEN_P54_MOV_ACK_RETIRE``,
       ``VEN_P54_CTRL_TARGET_READ`` / ``_SYSTEM``, ``VEN_RET_SHORT_WINDOW``, and
       ``VEN_FAST_RETRACE``).
   * - ``VEN_IDIV_ITER``
     - **Yes**
     - Replaces behavioral ``/`` and ``%`` operators with the synthesizable
       iterative radix-2 ``ven_idiv.sv`` divider.

Front-end, branch prediction, L1 caches & associative TLBs
==========================================================

The deployed hardware profile uses **full P5 8 KiB L1 caches and NO enabled L2**:

.. list-table::
   :header-rows: 1
   :widths: 30 14 56

   * - Define
     - In ``c0e3fe43``
     - Architectural / Datapath Effect
   * - ``VEN_ITLB_ASSOC_4WAY``
     - **Yes**
     - Tier-1 IPC enhancement: upgrades the I-TLB to **32 entries, 4-way
       set-associative** (``tlb_assoc.sv``), eliminating direct-mapped code-page
       conflict misses.
   * - ``VEN_DTLB_ASSOC_4WAY`` / ``VEN_DTLB_P54_LARGE``
     - **Yes**
     - Configures the **64-entry, 4-way set-associative D-TLB** supporting both
       4 KiB and 4 MiB PSE pages.
   * - ``VEN_FE_PIPE`` / ``VEN_FE_DTLB_MULTI`` / ``VEN_FE_DTLB_PERM`` / ``VEN_IFETCH_AUTH_MULTI``
     - **Yes**
     - Registers resident front-end I-TLB and D-TLB page translations to break
       combinational ``eip → TLB → cache`` timing loops.
   * - ``VEN_BTB_PIPE``
     - **Yes**
     - Pipelines resolve/update inputs into the dual-ported **256-entry 4-way
       BTB** (``bpred_btb.sv``).
   * - ``VEN_IC_BRAM`` / ``VEN_IC_RESIDENCY_SPAN`` / ``VEN_IC_PREFIX_SPAN`` / ``VEN_SFETCH_RESIDENT`` / ``VEN_SFETCH16_DEMAND``
     - **Yes**
     - Implements the 8 KiB L1 I-Cache in ``8`` ``RAMB36`` blocks + LUTRAM tags
       with resident dual-line span tracking and zero-bus-reread ``S_PIPE`` to
       slow-decode hand-offs.
   * - ``VEN_UOPCACHE`` / ``VEN_UOP_SFETCH`` / ``VEN_UOPCACHE_CHECK``
     - No (opt)
     - Optional predecode-on-fill micro-op cache (``uopcache.sv``; not enabled in
       ``c0e3fe43``, which decodes directly from ``icache.sv`` with fanout
       replication).
   * - ``VEN_L1_AXI`` / ``VEN_L1_HONOR_CD`` / ``VEN_CACHEINV_LOCAL``
     - **Yes**
     - Instantiates ``ventium_l1_axi`` (``ven_l1d`` + ``ven_axi_master`` +
       ``ven_cachemap``) with ``CR0.CD`` cache-disable enforcement. Note: in
       ``verif/tb``, you must **also pass** ``--l1-axi`` at runtime to route
       traffic through the AXI backend.
   * - ``VEN_L1D_BANKED_DATA`` / ``VEN_L1D_BANK0_SHARED_XLINE`` / ``VEN_L1D_TAG_LUTRAM`` / ``VEN_P54_DUAL_HIT`` / ``_LEGACY_CAPTURE``
     - **Yes**
     - Configures the **8-way 32-bit word-interleaved 8 KiB L1 D-Cache** and
       ``ven_p54_hit_return`` dual-port U+V hit return with LUTRAM tags.
   * - ``VEN_L1D_STORE_POLICY`` / ``VEN_P54_WBUF_PIPE_DISPATCH`` / ``_QUAD_COMBINE`` / ``_ADMIT_DISPATCH``
     - **Yes**
     - Enables write-back/write-allocate L1D store coalescing and pipelined
       write-buffer dispatch.
   * - ``VEN_L1D_FILL_FORWARD`` / ``_HIT_UNDER_FILL`` / ``_DATA_UNDER_IFILL`` / ``_PRIME_UNDER_FILL`` / ``VEN_L1D_*WINDOW*`` / ``VEN_L1D_CODE_*`` / ``VEN_L1D_*_PAYLOAD_SELECT``
     - **Yes**
     - Enables critical-word fill forwarding, L1D hit-under-ifill, warm read/write
       window reuse, physical snoop invalidation, and narrowed mux payload trees.

Shared pipelined x87 FPU & errata defines
=========================================

.. list-table::
   :header-rows: 1
   :widths: 30 14 56

   * - Define
     - In ``c0e3fe43``
     - Architectural / Datapath Effect
   * - ``VEN_FP_SHARED`` / ``VEN_FP_SHARED_DIRECT`` / ``VEN_FP_SHARED_EARLY_CMD``
     - **Yes**
     - Selects the area-shared pipelined 80-bit x87 FPU hierarchy in
       ``fp_shared/ven_fp_top.sv`` (``72,204`` LUTs, ``38`` DSP48E2 slices).
   * - ``VEN_FP_FXCH_QUEUE``
     - **Yes**
     - Enables the **zero-cycle FXCH rename queue**
       (``fp_shared/ven_fp_fxch_queue.sv``).
   * - ``VEN_FP_PIPE`` / ``VEN_FP_PIPE2`` / ``VEN_FP_PIPE_PAYLOAD_SELECT``
     - **Yes**
     - Enables the 2-stage deferred x87 arithmetic execute/commit pipeline
       (:doc:`microarch/fp-commit-pipeline`).
   * - ``VEN_FP_ASYNC`` / ``_BRANCH`` / ``_EARLY`` / ``_MEM`` / ``_STACK`` / ``_STREAM`` / ``VEN_FP_OPERAND_OVERLAP``
     - **Yes**
     - Overlaps asynchronous x87 execution with integer ``S_PIPE`` instructions,
       branches, and memory loads/stores while preserving exact ``#MF`` fault
       boundaries.
   * - ``VEN_FP_ARITH_FWD`` / ``_MEM_FWD`` / ``_STREAM`` / ``VEN_FP_MEM_LOADS`` / ``VEN_FP_LOAD64`` / ``VEN_FP_MEM_QUEUE*`` / ``VEN_FP_SCALAR_*`` / ``VEN_FP_*_EARLY_CMD`` / ``VEN_FP_POP_DRAIN`` / ``VEN_FP_RESIDENT_PRIME`` / ``VEN_FP_SHORT_WINDOW``
     - **Yes**
     - Enables fast 32/64-bit FP memory load queuing, back-to-back FP operand
       forwarding, and scalar dispatch into ``ven_fp_top``.
   * - ``VEN_SRT_ITER`` / ``VEN_SRT_REM_OPERAND_SPLIT`` / ``VEN_SRT_PAYLOAD_SELECT``
     - **Yes**
     - Instantiates the synthesizable multi-cycle radix-4 SRT divider, ``FSQRT``,
       and ``FPREM``/``FPREM1`` engine (``fpu_srt_div.sv``;
       :doc:`microarch/srt-divider`).
   * - ``VEN_BCD_ITER`` / ``VEN_TRANSCENDENTAL`` / ``VEN_FPREM``
     - **Yes**
     - Enables full hardware packed-BCD (``FBLD``/``FBSTP``), partial remainder
       (``FPREM``/``FPREM1``), and all 8 x87 transcendental instructions.
   * - ``VEN_FP_PC_RELAX`` / ``VEN_X87_MF_STRICT``
     - **Yes**
     - Supports single/double ``FCW.PC`` rounding precision (required by DirectX /
       DOS Quake / Windows 95) and strict pending-``#MF`` checks at waiting x87
       boundaries.
   * - ``VEN_SRT_FDIV_BUG`` / ``VEN_DIV_EXACT`` / ``VEN_FP_OVERLAP`` / ``VEN_FXCH_FREE``
     - No (sim)
     - Optional simulation/errata defines: buggy 1994 FDIV PLA, fast behavioral
       divider opt-out, and standalone M5 cycle-oracle study variants.

Platform, synthesis, simulation & debug defines
===============================================

.. list-table::
   :header-rows: 1
   :widths: 30 14 56

   * - Define
     - In ``c0e3fe43``
     - Purpose
   * - ``SYNTHESIS`` / ``VTM_NO_DPI`` / ``VEN_ALTSYNCRAM_XPM``
     - **Yes**
     - Strips simulation-only ``$fatal``/SVA constructs, elides DPI-C retirement
       imports in ``ventium_pkg.sv`` (also used by standalone ``verilator
       --lint-only``), and maps ``ao486`` RAM wrappers cleanly onto Xilinx XPM /
       BRAM primitives.
   * - ``VEN_CORE`` / ``VEN_DDR_POSTED`` / ``VEN_AO486_SINGLE_FILL``
     - **Yes**
     - Selects Ventium inside the ``ao486`` platform shim and enables the
       16-slot posted DDR4 write queue + RAW CAM bypass
       (``ven_ddram_axi_posted.sv``).
   * - ``VEN_AXI2AVL_BPIPE`` / ``_WRITE_THROUGH`` / ``_READ_THROUGH`` / ``VEN_AXI_READ_ON_FINAL_B``
     - **Yes**
     - Configures ``ven_axi2avalon.sv`` write-response pipelining and read-after-B
       ordering into PC/AT I/O and MMIO slaves.
   * - ``VEN_VGA_WIDE_STORE`` / ``VEN_VGA_FULL_STORE_SETUP`` / ``VEN_KBC_FAST`` / ``VEN_KBD_AUTOACK``
     - **Yes**
     - Platform bridge tuning for planar/linear VGA writes and PS/2 mailbox
       transfers; ``VEN_KV260_SOC`` is retained solely as the legacy compile-time
       ``soc_en`` interrupt/system seam alias inside ``ventium_top``.
   * - ``VEN_DBG_CORE`` / ``VEN_PERF_PROFILE`` / ``VEN_L1D_PERF`` / ``VEN_L2_PERF`` / ``VEN_SLOWOP_PERF``
     - **Yes**
     - Enables the ``ven_soc_dbg`` on-die debug/PMU bundle in synthesis; the
       ``*_PERF`` macros gate simulation-only ``ifndef SYNTHESIS`` performance
       counters (zero synthesized LUTs when ``SYNTHESIS`` is set).
   * - ``VEN_AXI_CDC``
     - Optional
     - Enables ``ven_axi_cdc.sv`` async-FIFO CDC inside ``ventium_l1_axi`` when
       tested standalone (on RK-XCZU15EG-F, 40→100 MHz CDC happens downstream of
       ``ven_ddram_axi_posted``).

Prohibited / retired legacy flags (do not revive)
=================================================

.. warning::

   Never define or re-enable any of the following retired macros:

   * ``VEN_CACHE_HALF`` — Retired 4 KiB half-L1 capacity hack from early
     KV260 experiments. ``ventium_top.sv`` fails elaboration immediately if
     defined.
   * ``VEN_IC_NARROWB`` — Retired narrow I-cache straddle-read pruning flag.
     ``ventium_top.sv`` fails elaboration immediately if defined.
   * ``EN_L2=1`` / ``VEN_EN_L2`` — Outer/northbridge L2 is disabled on the
     deployed platform (full P5 8 KiB L1s + posted DDR4 only; ``g_l2`` traps via
     ``$fatal`` at elaboration).
   * ``VEN_*_PS`` / ``VEN_PS_PROXY`` / ``VEN_FPTRAP`` / ``VEN_PBLOCK`` —
     Historical KV260 PS-peripheral / syscall-proxy / FPATAN-trap / floorplan
     experiments, superseded by full-RTL ``ao486_MiSTer`` + ``fp_shared/`` on
     RK-XCZU15EG-F.

Complete 161-define manifest of release ``c0e3fe43``
====================================================

For exact reproducibility, below is the complete sorted list of **161** defines
in ``fpga/known_good_defines.txt`` (SHA-256 prefix ``1d40a256`` on ``main``):

.. code-block:: text

   SYNTHESIS                              VEN_L1D_PERF
   VEN_ALTSYNCRAM_XPM                     VEN_L1D_PRIME_UNDER_FILL
   VEN_AO486_SINGLE_FILL                  VEN_L1D_RESPONSE_PAYLOAD_SELECT
   VEN_AXI2AVL_BPIPE                      VEN_L1D_STORE_POLICY
   VEN_AXI2AVL_READ_THROUGH               VEN_L1D_STORE_WINDOW_WARM
   VEN_AXI2AVL_WRITE_THROUGH              VEN_L1D_TAG_INVALIDATE
   VEN_AXI_READ_ON_FINAL_B                VEN_L1D_TAG_LUTRAM
   VEN_BCD_ITER                           VEN_L1D_TWO_WINDOW_KEEP_STORE
   VEN_BTB_PIPE                           VEN_L1D_TWO_WINDOW_REUSE
   VEN_CACHEINV_LOCAL                     VEN_L1D_WINDOW_KEEP_STORE
   VEN_CORE                               VEN_L1D_WINDOW_REUSE
   VEN_DBG_CORE                           VEN_L1D_WINDOW_WRITE_UPDATE
   VEN_DDR_POSTED                         VEN_L1_AXI
   VEN_DTLB_ASSOC_4WAY                    VEN_L1_HONOR_CD
   VEN_DTLB_P54_LARGE                     VEN_L2_PERF
   VEN_FAST_BYTE_ALU                      VEN_L2_STREAM_ANY
   VEN_FAST_BYTE_MEM_CMP                  VEN_L2_STREAM_CWF
   VEN_FAST_BYTE_SHIFT                    VEN_P54_AGI_WRITE_MASK
   VEN_FAST_MEM_ADC                       VEN_P54_CTRL_TARGET_READ
   VEN_FAST_MEM_ADD                       VEN_P54_CTRL_TARGET_SYSTEM
   VEN_FAST_MEM_ADD7                      VEN_P54_DUAL_BYTE_LOAD_PAIR
   VEN_FAST_MEM_ALU                       VEN_P54_DUAL_HIT
   VEN_FAST_MEM_MOV7                      VEN_P54_DUAL_HIT_LEGACY_CAPTURE
   VEN_FAST_MOFFS_STORE                   VEN_P54_DUAL_LOAD_PAIR
   VEN_FAST_RETRACE                       VEN_P54_DUAL_READ_ALU_PAIR
   VEN_FAST_ROR_IMM                       VEN_P54_DUAL_STORE_PAIR
   VEN_FAST_UNARY_R                       VEN_P54_INT_EXEC_OCC
   VEN_FAST_XCHG_R                        VEN_P54_LOAD_STORE_PAIR
   VEN_FE_DTLB_MULTI                      VEN_P54_MOV_ACK_RETIRE
   VEN_FE_DTLB_PERM                       VEN_P54_PREFIX66_REG
   VEN_FE_PIPE                            VEN_P54_PREFIX66_SYSTEM
   VEN_FPREM                              VEN_P54_PREFIX_AGI
   VEN_FP_ARITH_FWD                       VEN_P54_PREFIX_EX_CHAIN
   VEN_FP_ARITH_MEM_FWD                   VEN_P54_PREFIX_EX_SYSTEM
   VEN_FP_ARITH_STREAM                    VEN_P54_SDISPATCH_AGI
   VEN_FP_ASYNC                           VEN_P54_WBUF_ADMIT_DISPATCH
   VEN_FP_ASYNC_BRANCH                    VEN_P54_WBUF_PIPE_DISPATCH
   VEN_FP_ASYNC_EARLY                     VEN_P54_WBUF_QUAD_COMBINE
   VEN_FP_ASYNC_MEM                       VEN_PERF_PROFILE
   VEN_FP_ASYNC_STACK                     VEN_PIPE_MEM_CHAIN
   VEN_FP_ASYNC_STREAM                    VEN_PIPE_REG_LOAD_PRIME
   VEN_FP_FXCH_QUEUE                      VEN_PIPE_SDECODE
   VEN_FP_LOAD64                          VEN_PIPE_SDISPATCH
   VEN_FP_LOAD64_PAYLOAD_SELECT           VEN_PIPE_SDISPATCH_SHORT
   VEN_FP_LOAD_EARLY_CMD                  VEN_RAW_AGI_PRIME
   VEN_FP_LOAD_PAYLOAD_SELECT             VEN_RAW_BRANCH_FALLTHROUGH_PRIME
   VEN_FP_MEM_ADMIT                       VEN_RAW_HELD_READ_PRIME
   VEN_FP_MEM_LOADS                       VEN_RAW_V_READ_PRIME
   VEN_FP_MEM_QUEUE                       VEN_REF_OPERAND_PRIME
   VEN_FP_MEM_QUEUE64                     VEN_REP_CONT_NO_UOP
   VEN_FP_MISC_EARLY_DONE                 VEN_REP_MOVS_CONT
   VEN_FP_OPERAND_OVERLAP                 VEN_REP_MOVS_LOAD_FUSE
   VEN_FP_PC_RELAX                        VEN_REP_MOVS_STREAM
   VEN_FP_PIPE                            VEN_REP_STOS_STREAM
   VEN_FP_PIPE2                           VEN_RET_SHORT_WINDOW
   VEN_FP_PIPE_PAYLOAD_SELECT             VEN_SEG_ENFORCE
   VEN_FP_POP_DRAIN                       VEN_SFETCH16_DEMAND
   VEN_FP_REG_ADMIT                       VEN_SFETCH_RESIDENT
   VEN_FP_RESIDENT_PRIME                  VEN_SLOWOP_PERF
   VEN_FP_SCALAR_DISPATCH                 VEN_SRT_ITER
   VEN_FP_SCALAR_LOAD_CMD                 VEN_SRT_PAYLOAD_SELECT
   VEN_FP_SHARED                          VEN_SRT_REM_OPERAND_SPLIT
   VEN_FP_SHARED_DIRECT                   VEN_STORE_DISPATCH
   VEN_FP_SHARED_EARLY_CMD                VEN_SYS_FASTLOAD_BOUNDED
   VEN_FP_SHORT_WINDOW                    VEN_SYS_FASTLOAD_FLAT
   VEN_FP_STORE_EARLY_CMD                 VEN_SYS_FASTPATH
   VEN_IC_BRAM                            VEN_SYS_FASTPATH_RELOC
   VEN_IC_PREFIX_SPAN                     VEN_SYS_FASTSTORE_FLAT
   VEN_IC_RESIDENCY_SPAN                  VEN_TRANSCENDENTAL
   VEN_IDIV_ITER                          VEN_VGA_FULL_STORE_SETUP
   VEN_IFETCH_AUTH_MULTI                  VEN_VGA_WIDE_STORE
   VEN_ITLB_ASSOC_4WAY                    VEN_X87_MF_STRICT
   VEN_KBC_FAST                           VTM_NO_DPI
   VEN_KBD_AUTOACK
   VEN_KV260_SOC
   VEN_L1D_BANK0_SHARED_XLINE
   VEN_L1D_BANKED_DATA
   VEN_L1D_CODE_BUFFER
   VEN_L1D_CODE_PAYLOAD_SELECT
   VEN_L1D_CODE_STREAM
   VEN_L1D_CODE_TAG_INVALIDATE
   VEN_L1D_CODE_WORD_REUSE
   VEN_L1D_DATA_UNDER_IFILL
   VEN_L1D_FILL_FORWARD
   VEN_L1D_HIGH_PAYLOAD_SELECT
   VEN_L1D_HIT_UNDER_FILL
   VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE
   VEN_L1D_PAYLOAD_CODE_HINT
