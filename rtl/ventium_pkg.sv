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
`endif

endpackage : ventium_pkg
