// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ventium_pkg.sv — shared architectural types + the DPI retire import.
//
// Ventium: a high-fidelity Verilog replica of the Intel Pentium (P5/P54C).
// See PLAN.md §4 (verification), §6 (block decomposition) and
// docs/rtl-interface.md (the RTL<->testbench contract this package realises).
//
// This package is `import`ed by ventium_top and the core blocks. It carries:
//   * the IA-32 architectural-state types the retire point assembles, and
//   * the single DPI-C `vtm_retire` observation callback, declared *verbatim*
//     from docs/rtl-interface.md §2 (the comparator parses by field name, so
//     the signature must match exactly).
//
// Standalone lint: define VTM_NO_DPI to elide the import so the RTL lints
// without a C testbench present (docs/rtl-interface.md §2 last bullet).

package ventium_pkg;

  // ---------------------------------------------------------------------------
  // Architectural register-file layout (IA-32 integer + segment state).
  // Mirrors the func-mode .vtrace fields in docs/trace-format.md §2.2 and the
  // shared parser order in verif/diff/tracefmt.py (GPR_KEYS / SEG_KEYS).
  // ---------------------------------------------------------------------------

  // GPR indices, in the trace's canonical order: eax ecx edx ebx esp ebp esi edi
  // (tracefmt.py GPR_KEYS). Used to index the architectural register file.
  typedef enum logic [2:0] {
    R_EAX = 3'd0,
    R_ECX = 3'd1,
    R_EDX = 3'd2,
    R_EBX = 3'd3,
    R_ESP = 3'd4,
    R_EBP = 3'd5,
    R_ESI = 3'd6,
    R_EDI = 3'd7
  } gpr_e;

  localparam int NUM_GPR = 8;
  localparam int NUM_SEG = 6;   // cs ss ds es fs gs

  // Post-commit architectural snapshot the retire point hands to vtm_retire.
  // Field names/order track tracefmt.py so integration stays mechanical.
  typedef struct packed {
    logic [31:0] eflags;
    logic [31:0] eax, ecx, edx, ebx, esp, ebp, esi, edi;
    logic [15:0] cs, ss, ds, es, fs, gs;
  } arch_state_t;

  // ---------------------------------------------------------------------------
  // DPI retire callback — the observation contract (docs/rtl-interface.md §2).
  //
  // The RTL imports this and calls it once per retired instruction, in
  // architectural order, with the instruction's fetch PC and post-commit state.
  // The Verilator C++ testbench (verif/tb/) implements it and emits one
  // func-mode .vtrace line per call.
  //
  // Declared VERBATIM from rtl-interface.md §2. Guarded by VTM_NO_DPI so the
  // core lints/elaborates standalone (no C symbol to bind) — see §2 last bullet.
  // ---------------------------------------------------------------------------
`ifndef VTM_NO_DPI
  import "DPI-C" context function void vtm_retire(
      input longint unsigned n,        // retire seq, 0-based, monotonic
      input int      unsigned pc,      // fetch vaddr of retired insn
      input int      unsigned eflags,
      input int      unsigned eax, input int unsigned ecx,
      input int      unsigned edx, input int unsigned ebx,
      input int      unsigned esp, input int unsigned ebp,
      input int      unsigned esi, input int unsigned edi,
      input shortint unsigned cs,  input shortint unsigned ss,
      input shortint unsigned ds,  input shortint unsigned es,
      input shortint unsigned fs,  input shortint unsigned gs);

  // ---------------------------------------------------------------------------
  // DPI x87 retire callback — the FP observation contract (M3+).
  //
  // rtl-interface.md §2 reserved a second optional DPI import for the x87 FPU.
  // On every retirement where the x87 architectural state may have changed, the
  // core calls vtm_retire(...) (integer state, unchanged) AND vtm_retire_x87(...)
  // with the SAME retire sequence number `n` and the POST-COMMIT x87 state. The
  // testbench (dpi_retire.cpp) stashes the x87 state keyed by `n`; the matching
  // vtm_retire emits ONE func record carrying both halves, and the trace header
  // declares x87:true (TB --x87 flag). If the core does NOT call this for a given
  // `n` under --x87, the TB emits zeros for the x87 fields (well-formed record).
  //
  // 80-bit passing convention (docs/rtl-interface.md §2 "x87 trace hook"):
  //   each st(i) is the canonical floatx80 layout split into
  //     st<i>_lo : longint  unsigned  -- mantissa, bits [63:0]
  //     st<i>_hi : shortint unsigned  -- sign|exponent, bits [79:64]
  //   so the reassembled 80-bit value is {st<i>_hi, st<i>_lo} — exactly the
  //   encoding gen_trace.py emits, so the 20-hex-digit st-register strings
  //   compare directly. Control words (fctrl/fstat/ftag) are 16-bit fields
  //   carried in `int unsigned` slots (like the selectors in vtm_retire); the TB
  //   masks to 16 bits when formatting. fop/fiseg/fioff/foseg/fooff are NOT
  //   passed — QEMU user-mode reports them as 0, so the TB emits 0 (m3-fpu-spec).
  //
  // Guarded by VTM_NO_DPI alongside vtm_retire so the core lints/elaborates
  // standalone without a C testbench (docs/rtl-interface.md §2 last bullet).
  import "DPI-C" context function void vtm_retire_x87(
      input longint  unsigned n,         // SAME retire seq as the paired vtm_retire
      input int      unsigned fctrl,     // control word (16-bit value in 32b slot)
      input int      unsigned fstat,     // status  word (16-bit value in 32b slot)
      input int      unsigned ftag,      // tag     word (16-bit value in 32b slot)
      input longint  unsigned st0_lo, input shortint unsigned st0_hi,
      input longint  unsigned st1_lo, input shortint unsigned st1_hi,
      input longint  unsigned st2_lo, input shortint unsigned st2_hi,
      input longint  unsigned st3_lo, input shortint unsigned st3_hi,
      input longint  unsigned st4_lo, input shortint unsigned st4_hi,
      input longint  unsigned st5_lo, input shortint unsigned st5_hi,
      input longint  unsigned st6_lo, input shortint unsigned st6_hi,
      input longint  unsigned st7_lo, input shortint unsigned st7_hi);

  // ---------------------------------------------------------------------------
  // DPI cycle retire callback — the CYCLE observation contract (M4).
  //
  // The M4 dual-issue (U/V) pipeline core calls vtm_retire_cycle(...) on the
  // SAME retirement as vtm_retire(...) (same retire sequence number `n`),
  // conveying WHICH pipe the instruction issued to and WHETHER it issued paired
  // with its sibling this clock. This carries no cycle count: the testbench owns
  // the core-clock counter and stamps `cyc = clock-count-at-retire` itself
  // (docs/m4-pipeline-spec.md "RTL cycle-trace producer", docs/trace-format.md
  // §2.3). The TB in --cycle mode stashes {pipe,paired} keyed by `n`; the paired
  // vtm_retire then emits ONE cycle-mode record carrying the TB's clock count
  // plus the pipe/paired the core reported. Two instructions retiring in the
  // same clock (a paired issue) read the same TB clock and so share `cyc`, and
  // the V-pipe sibling carries paired=true.
  //
  // pipe encoding (docs/trace-format.md §2.3 "pipe": "U"/"V"/"-"):
  //   0 = U   (the U pipe / sole pipe / serialized-microcoded issue)
  //   1 = V   (the V pipe — only valid when paired)
  //   2 = none (microcoded/complex op not attributed to a pipe -> "-")
  //
  // If the core does NOT call vtm_retire_cycle for a retirement under --cycle,
  // the TB defaults pipe=U paired=false (a well-formed record) — so a not-yet-
  // pipelined core still produces a coherent cycle vtrace (the cycle bands will
  // simply MISS until the real pipeline drives these signals).
  //
  // Guarded by VTM_NO_DPI alongside vtm_retire so the core lints/elaborates
  // standalone without a C testbench (docs/rtl-interface.md §2 last bullet).
  import "DPI-C" context function void vtm_retire_cycle(
      input longint unsigned n,        // SAME retire seq as the paired vtm_retire
      input int     unsigned pipe,     // 0=U, 1=V, 2=none
      input int     unsigned paired);  // 0/1: issued paired with its sibling

  // ---------------------------------------------------------------------------
  // DPI system retire callback — the M2S.1 SYSTEM-state contract.
  //
  // A SYSTEM-mode core (boot_mode=1) calls vtm_retire_sys(...) with the SAME `n`
  // as the paired vtm_retire, carrying the post-commit control registers
  // cr0/cr2/cr3/cr4. The TB stashes them keyed by `n`; the matching vtm_retire
  // (under --system) drains them and emits the cr0..cr4 fields plus the
  // selectors (already in vtm_retire), and the header declares sys:true. In user
  // mode the core never calls this, so the user trace is unchanged. Segment
  // hidden base/limit/attr are NOT carried here (the gdbstub golden does not
  // expose them; they are exercised indirectly via addressing, m2s1 spec §Trace).
  //
  // Guarded by VTM_NO_DPI alongside the others so the core lints standalone.
  import "DPI-C" context function void vtm_retire_sys(
      input longint unsigned n,        // SAME retire seq as the paired vtm_retire
      input int     unsigned cr0, input int unsigned cr2,
      input int     unsigned cr3, input int unsigned cr4);
`endif

endpackage : ventium_pkg
