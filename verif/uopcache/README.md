# `verif/uopcache` — Predecode Length, Front-End Residency Spans, and Uop-Cache Verification

## Scope and Architectural Invariants

`verif/uopcache/` verifies instruction predecode length scanning
(`rtl/mem/ven_predecode_len.sv`), the optional predecode-on-fill micro-op cache
(`rtl/mem/uopcache.sv`, `+define+VEN_UOPCACHE`), compact I-cache front-end residency/prefix
span probes (`VEN_IC_RESIDENCY_SPAN`, `VEN_IC_PREFIX_SPAN`), resident slow-decode capture
(`VEN_PIPE_SDECODE`), and local cache-invalidation decode (`VEN_CACHEINV_LOCAL`):

1. **BRAM Port-Identity Prerequisite:**
   - `VEN_UOPCACHE` requires `VEN_IC_BRAM` (enforced by an elaboration `$fatal` in
     `rtl/core/core.sv`) so dual-port `rdA`/`rdB` `(set, way)` ownership is tracked
     accurately across branch redirects, port collisions, and bypass fills.
   - `VEN_UOPCACHE` is mutually exclusive with raw-decode `VEN_P54_PREFIX66_REG`.
2. **Slot-to-Live-Decode Equivalence (`+define+VEN_UOPCACHE_CHECK`):**
   - Simulation-only lockstep oracle asserting that every consumed predecoded slot matches
     live combinational `decode.sv` output without adding hardware to synthesis builds.
3. **Exact Mode, Snoop, Line-Tail & `#UD` Resynchronization:**
   - Default operand/address size flips (`CS.D/B`, real/PM/V86 transitions —
     `tb_uop_modeflip_guard.sv`) and physical store snoops (`run-crossline-smc.py`) must
     never serve stale predecoded descriptors.
   - Line-tail local boundary checks (`VEN_UOP_TAIL_LOCAL`, `tb_uopcache_tail_local.sv`)
     reject truncated multi-byte instructions straddling a 32-byte I-cache line end unless
     an explicit cross-line mechanism verifies both resident lines.
   - Fixed-`#UD` instructions and page-faulting redirects (`make verify-uop-resync`,
     `tb_uopcache_pf_redir.sv`, `tb_uopcache_resync_corners.sv`) resynchronize cleanly to
     `S_DECODE` with exact architectural `EIP` and fault delivery.
4. **Compact Front-End Span Probes (`VEN_IC_RESIDENCY_SPAN`, `VEN_IC_PREFIX_SPAN`):**
   - Replaces wide repeated `ic_present`/`ic_buffered` full-tag scans across `S_FETCH`,
     `VEN_PIPE_SDECODE`, and `VEN_P54_PREFIX_EX_CHAIN` with compact
     `ic_front_a`/`ic_front_b` port-tag probes, preserving exact duplicate-tag and
     fetch-bypass priority while cutting front-end LUT congestion.

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**. Unmeasured experimental-branch
> configurations do not inherit this baseline.

| Sub-Area | Deployed in `c0e3fe43` (`main`) | Experimental / Opt-In (`experimental/uv-fast-ipc-apr`) | Unapplied / Archived Proposals |
| --- | --- | --- | --- |
| **Front-End Fetch & Span Probes** | `VEN_IC_BRAM`, `VEN_PIPE_SDECODE`, `VEN_SFETCH_RESIDENT`, `VEN_IC_RESIDENCY_SPAN`, `VEN_IC_PREFIX_SPAN`, `VEN_CACHEINV_LOCAL`, plus `pf_fill_addr_rep[0..3]` fanout replication | Standalone miter harnesses in `proposals/ic_residency_span/` and `proposals/cacheinv_local/` | — |
| **Decoded-Line Store vs. Raw Decode** | Raw dual-decode (`decode.sv` + `VEN_P54_PREFIX66_REG`) with `VEN_UOPCACHE` **off** (eliminating >15K FFs and regional `u_icache` routing hotspots to close 40.264 MHz post-route STA; `ven_predecode_len.sv` and `uopcache.sv` remain in `rtl_ven_core.f`) | `VEN_UOPCACHE` + `VEN_UOP_SFETCH` + `VEN_UOP_TAIL_LOCAL` (active in legacy `KV_FULL_DEFS` Verilator targets and gated by `make verify-uop-resync`) | — |
| **Uop-Cache Capacity & Boundary Extensions** | — | `VEN_UOP_16_SLOTS` (16-slot vs. 12-slot decoded-line bank), `VEN_UOP_CROSSLINE` (supplemental cross-line descriptor), `VEN_UOP_SLOW_LEN_HINT` (4-bit non-executable length hint in invalid map entries for unprefixed 32-bit x87 memory ops and `MOVZX`/`MOVSX`) | `VEN_UOP_SEEK7` (`proposals/seek7_sep20*` — `min(anchor - offset, 7)` `W_SEEK` repair step; archived patch/leaf only) |

---

## Active Testbenches and Gate Scripts

| Gate Family | Runner Scripts | Primary Testbenches / Fixtures |
| --- | --- | --- |
| **Resync & Line-Tail Correctness** | `run-uop-resync-gate.sh` (`make verify-uop-resync`), `run-uop-resync-corners-gate.sh`, `run-uop-tail-local-gate.sh`, `run-uop-tail-local-core-gate.sh`, `run-uop-modeflip-guard-gate.sh`, `run-uop-pf-redir-gate.sh`, `run-uop-repair-gate.sh`, `run-uopcache-skip-gate.sh` | `tb_uopcache_resync_corners.sv`, `tb_uopcache_tail_local.sv`, `tb_uop_modeflip_guard.sv`, `tb_uopcache_pf_redir.sv`, `tb_uopcache_repair.sv`, `tb_uopcache_skip.sv`, `t_tail_local_core.s` |
| **Predecode & Span Miters** | `run-predecode-len-gate.sh`, `run-decode-tail-invariance.sh`, `run-ic-front-span-miter.sh`, `run-pipe-sdecode-guard.sh`, `run-pipe-sdecode-ab.py`, `proposals/ic_residency_span/run-miter.sh`, `proposals/cacheinv_local/run.py` | `tb_predecode_len.sv`, `tb_decode_tail_invariance.sv`, `tb_ic_front_span_miter.sv`, `tb_pipe_sdecode_guard.sv`, `tb_seg_ext_size_guard.sv`, `tb_ic_residency_span.sv`, `t_pipe_sdecode.s` |
| **Optional Uop-Cache Experiments** | `run-uop-capacity-gate.sh`, `run-uop-crossline-gate.sh`, `run-crossline-ifetch.py`, `run-crossline-smc.py`, `run-seam-capacity-ab.py`, `run-slow-len-hint-gate.sh`, `run-slow-len-miter.sh`, `run-slow-len-tail-ab.py`, `run-seek7-draft-leaf.sh`, `run-boundary-ipc.sh` | `tb_uopcache_capacity.sv`, `tb_uopcache_crossline.sv`, `tb_uop_slow_len_hint.sv`, `tb_uopcache_seek7.sv`, `t_crossline_ifetch.S`, `t_crossline_smc.s`, `t_many_seams.s`, `t_slow_len_tail_smc.s`, `t_boundary_ipc.s` |

---

## Safe Execution Guidelines

- Export `TMPDIR=/home/yukidama/external/tmp` and compile into private object directories;
  never mutate canonical `verif/tb/obj_dir`.
- Keep `+define+VEN_UOPCACHE` (+ `+define+VEN_IC_BRAM`) and `+define+VEN_P54_PREFIX66_REG`
  in separate build directories, and pass `--l1-axi` explicitly when executing
  `+define+VEN_L1_AXI` core binaries.

```bash
# Run the uop-cache fixed-#UD resynchronization and predecode/span gates:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  make verify-uop-resync
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/uopcache/run-predecode-len-gate.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/uopcache/run-ic-front-span-miter.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/uopcache/run-uop-tail-local-gate.sh
```
