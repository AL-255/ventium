# `verif/bytemov` — Byte/Narrow Fast-Path, `VEN_FAST_MEM_EXT`, and Provenance Gates

## Scope and Architectural Invariants

`verif/bytemov/` verifies narrow-width (`8`-bit / `16`-bit) fast-path data movement and
ALU/shift execution, 7-byte `SIB + disp32` memory `MOV` admission (`VEN_FAST_MEM_MOV7`),
zero/sign-extending memory loads (`MOVZX`/`MOVSX` and `VEN_FAST_MEM_EXT`), 16-bit
`SHLD`/`SHRD` operand masking, P5 data alignment, and protected-mode stack vs.
explicit-operand segment provenance:

1. **Byte GPR Parent Mapping (`w8`, `src_hi8`, `dst_hi8`):**
   - High-byte register encodings (`AH`/`CH`/`DH`/`BH`, indices `4..7`) must map
     data-register reads, partial destination merges, and RAW/WAW pairing masks to their
     parent 32-bit GPR (`EAX`..`EBX`), **never** `ESP`..`EDI` (preventing false `ESP` WAW
     exceptions on `AH`).
   - Address `ModR/M` and `SIB` base/index register indices are never remapped.
2. **Flag Preservation on `MOV`:** Fast-path `88`/`8A`/`89`/`8B` `MOV` and `MOVZX`/`MOVSX`
   packets keep `wflags = 1'b0`; combinational ALU flag outputs never overwrite
   architectural `EFLAGS`.
3. **Source-Exact Memory Extent (`K_EXT`):** Narrow memory loads size page-split detection
   (`xp_end`/`xp_cross`), segment-limit checks, and byte-exact MMIO `ARSIZE` / lane strobes
   by the **source** width (`1` or `2` bytes), never the `16`/`32`-bit destination GPR merge
   width.
4. **Stack vs. Explicit-Operand Segment Provenance:**
   - `ENTER` frame pushes and display-pointer copies always govern under `SS` regardless of
     segment-override prefixes (`t_enter_provenance.S`).
   - `POP [mem]` reads the stack under `SS` and writes the explicit destination under the
     decoded operand segment; `PUSH [mem]` and near `CALL [mem]` read their source under the
     decoded segment and push under `SS` (`t_operand_provenance.S`).
   - Individual multi-byte stack accesses at `0xFFFFFFFE` against a flat `0xFFFFFFFF` limit
     fault `#SS(0)` per Intel Pentium Vol. 3 §12.2.2 rather than wrapping modulo $2^{32}$,
     while pointer wrap *between* aligned slots (`ESP = 0 -> 0xFFFFFFFC`) remains legal
     (`t_frame_ss_limit.S`).
5. **16-Bit `SHLD`/`SHRD` Pre-Shift Masking:** Shared double-precision shift helpers in
   `rtl/core/ventium_alu_pkg.sv` mask 16-bit operands prior to shifting so upper 32-bit GPR
   bits never corrupt word shifts (`tb_shld_width.sv`, Windows 95 VMM32 decompressor
   witness).

---

## `MOVZX` / `MOVSX` Fast Memory Loads and `VEN_FAST_MEM_EXT` (`0F B6` / `B7` / `BE` / `BF`)

Ventium verifies zero- and sign-extending loads (`0F B6` `MOVZX r, r/m8`, `0F B7` `MOVZX r,
r/m16`, `0F BE` `MOVSX r, r/m8`, `0F BF` `MOVSX r, r/m16`) across two complementary RTL
layers (referenced by `docs/sphinx/isa/opcode-map.rst`):

1. **Canonical `K_EXT` Source-Width & Resident Protected-Mode Dispatch (Deployed in
   `c0e3fe43`):**
   - `rtl/core/decode_stages.sv` decodes `0F B6`/`B7`/`BE`/`BF` into `K_EXT` with
     `d_ext_srcw = 1` or `2` independent of destination `d_w = 2` or `4`, and
     `rtl/core/core.sv` drives `load_beat_w = q_ext_srcw` whenever `state == S_LOAD &&
     q_kind == K_EXT`. This prevents false `#PF`/`#GP` faults at page/segment boundaries and
     prevents over-wide MMIO device reads (`tb_ext_width_mmio.sv`, `run-ext-width-gate.py`).
   - Under `VEN_PIPE_SDISPATCH` + `VEN_P54_INT_EXEC_OCC` + `VEN_P54_PREFIX_EX_CHAIN` +
     `VEN_REF_OPERAND_PRIME` (all active in `c0e3fe43`), unprefixed resident `MOVZX`/`MOVSX`
     instructions dispatch without slow fetch and overlap their `0F` prefix `D1` clock while
     honoring P5's 3-clock `EX` occupancy.
2. **Direct `S_PIPE` Executable Descriptor Option (`+define+VEN_FAST_MEM_EXT`, Default-Off
   Experimental):**
   - Guarded in `rtl/core/decode.sv`, `rtl/core/ventium_decode_pkg.sv`, and
     `rtl/core/core_fastpath.svh` (`FP_LOAD_ZX8`..`FP_LOAD_SX16`), `VEN_FAST_MEM_EXT` admits
     unprefixed `default32`/`address32` memory forms (`mod != 2'b11`, destination `r32 !=
     ESP`, total length `<= 7` bytes) directly into `S_PIPE` as non-pairable (`NP`, minimum
     2-clock occupancy) loads excluded from `VEN_PIPE_MEM_CHAIN`.
   - Eight-byte `0F + op + ModRM + SIB + disp32`, 16-bit, prefixed, `ESP`-destination, and
     register encodings remain on `S_DECODE`. Verified across isolated miter
     (`run-fast-ext-draft-leaf.sh`), matched whole-core A/B (`run-fast-ext-ab.py`), hot/NC
     geometry (`run-ext-hot-geometry.py`, `run-ext-nc-geometry.py`), IRQ (`run-ext-irq.py`),
     debug (`run-ext-debug.py`), and SMC (`run-ext-smc.py`); kept default-off outside
     `c0e3fe43`.

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**. Unmeasured experimental options do not
> inherit this baseline.

| Category | Features / Defines | Status |
| --- | --- | --- |
| **Deployed in `c0e3fe43` (`main`)** | `88`/`8A` byte `MOV` fast path, 7-byte `SIB+disp32` `MOV` (`VEN_FAST_MEM_MOV7`), fast byte ALU/shift/mem-CMP (`VEN_FAST_BYTE_ALU`, `VEN_FAST_BYTE_SHIFT`, `VEN_FAST_BYTE_MEM_CMP`), `K_EXT` narrow `load_beat_w` + resident `VEN_PIPE_SDISPATCH` `MOVZX`/`MOVSX`, 16-bit `SHLD`/`SHRD` masking, and `ENTER` / `POP [mem]` / stack-limit provenance (`VEN_SEG_ENFORCE`). | **Board-qualified** (40.264 MHz post-route STA sign-off; CoreMark + Win95 + Quake `demo1` PASS) |
| **Experimental / Default-Off (`experimental/uv-fast-ipc-apr`)** | `VEN_FAST_MEM_EXT` (`S_PIPE` `0F B6`/`B7`/`BE`/`BF` `FP_LOAD_ZX8..SX16` direct descriptors). | **Default-off in RTL** (leaf + bounded whole-core A/B verified; not enabled in `c0e3fe43`) |
| **Unapplied Proposal Drafts** | `VEN_FAST_BYTE_ACC` (`proposals/byte_alu_reg_sep20/`, unprefixed `24 ib` `AND AL,imm8` and `3C ib` `CMP AL,imm8`). | **Archived patch/miter only** (not applied to production RTL) |

---

## Active Testbenches and Gate Scripts

| Verification Area | Runner Scripts | Testbenches / Fixtures |
| --- | --- | --- |
| **Byte `MOV`, ALU & Shift Datapaths** | `run-byte-pipes-gate.sh`, `run-byte-alu-decode-gate.sh`, `run-byte-shift-decode-gate.sh`, `run-byte-alu-draft-leaf.sh`, `run-byte-alu-ab.py` | `tb_byte_meta.sv`, `tb_byte_pipes.sv`, `tb_byte_alu_decode.sv`, `tb_byte_shift_decode.sv`, `t_byte_alu_acc.S` |
| **7-Byte `MOV7` (`VEN_FAST_MEM_MOV7`)** | `run-mov7-gate.sh` (9,216 encodings), `run-mov7-core-gate.sh` (`VEN_PIPE_RETIRE_WITNESS=1`), `run-mov7-page-gate.sh` (paged `#PF`/`CR0.WP`/retry) | `tb_mov7.sv`, `t_mov7_core.s` |
| **`K_EXT` Width & `VEN_FAST_MEM_EXT`** | `run-ext-width-mmio-gate.sh`, `run-ext-width-gate.py`, `run-fast-ext-draft-leaf.sh`, `run-fast-ext-ab.py`, `run-ext-memory-hot.py`, `run-ext-hot-geometry.py`, `run-ext-nc-geometry.py`, `run-ext-irq.py`, `run-ext-debug.py`, `run-ext-smc.py` | `tb_ext_width_mmio.sv`, `tb_fast_ext_miter_body.svh`, `t_ext_width.S`, `t_ext_memory_hot.S`, `t_ext_nc.S`, `t_ext_irq.S`, `t_ext_debug.S`, `t_ext_smc.S` |
| **Provenance, Alignment & `SHLD`/`SHRD`** | `run-enter-provenance-gate.py`, `run-operand-provenance-gate.py`, `run-frame-ss-limit-gate.py`, `run-p5-data-alignment-gate.sh` | `t_enter_provenance.S`, `t_operand_provenance.S`, `t_frame_ss_limit.S`, `tb_p5_data_alignment.sv`, `tb_shld_width.sv` |

---

## Safe Execution Guidelines

- Always export `TMPDIR=/home/yukidama/external/tmp` and compile into private object
  directories (`FULL_P5_SNAPSHOT_OBJDIR=...`); pass `--l1-axi` explicitly when executing
  `+define+VEN_L1_AXI` core binaries.

```bash
# Run Verilator byte-pipes, 7-byte MOV decoder, and K_EXT narrow MMIO width gates:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/bytemov/run-byte-pipes-gate.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/bytemov/run-mov7-gate.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/bytemov/run-ext-width-mmio-gate.sh

# Run Icarus pure helper checks into scratch under /home/yukidama/external/tmp:
iverilog -g2012 -s tb_shld_width -o /home/yukidama/external/tmp/ventium_tb_shld_width.vvp \
  rtl/core/ventium_alu_pkg.sv verif/bytemov/tb_shld_width.sv && \
  vvp /home/yukidama/external/tmp/ventium_tb_shld_width.vvp
```
