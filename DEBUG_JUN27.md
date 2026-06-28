# DOS-Quake bring-up debug log — 2026-06-27

End goal: a Verilator sim of the **full SoC** (Core + System Bridge + Peripherals) that boots
FreeDOS, runs Quake, renders frames, and survives long runs.

Status: **(1) FreeDOS boot — DONE & validated. (2) Quake — the #GP that halted it is now FIXED
(runs past the old fault to 15M+ instructions); render-frame confirmation in progress. (3) clean
long runs — the blocking fault is gone; long-run soak in progress.**

---

## 1. What is FIXED (committed, validated)

| commit    | fix |
|-----------|-----|
| `914ec9e` | POP r/m16 paging store used the SS base, not the operand DS base (DOS-Quake #GP) |
| `816e7e0` | same-priv PM INT pushed the handler CS, not the interrupted CS (DOS-Quake #GP) |
| `3925df5` | implement PROTECTED-mode LSS/LFS/LGS (was real-mode-only → HALT) |
| **(this)** | **S_LOAD2 paging-lookup `cur_lin` only covered CMPS — far-ptr seg-load / BOUND / CMPXCHG8B / far JMP-CALL-indirect 2nd read translated the WRONG linear under paging (DOS-Quake null-SS #GP)** |

Validation (all green, regression-gated, re-run after the new fix):
- `make verify`     → 98/98 functional GREEN (every program diff-clean vs QEMU, incl. x87)
- `make verify-sys` → **949/949 EQUIVALENT** (cr0..cr4 + selectors + GPRs + eflags + eip)
- DOS-Quake SoC sim → **runs past the old #GP (eip=0x408d, ~8.9M insn) to 15M+ with no fault**

---

## 2. The bug that was just fixed — DOS-Quake null-SS #GP (ROOT-CAUSED + FIXED)

### Symptom
Quake's go32/CWSDPMI runtime ran ~8.9M instructions then faulted:
```
GUESTCON: General Protection Fault at eip=408d; flags=3046  error=0000 (null selector)
```
The faulting instruction is the DPMI AX=0x300 return: `lss esp, %cs:0x409d`
(`66 2e 0f b2 26 9d 40` at cs=0x2b:0x408d). It loaded a **null SS** → #GP, before any frame rendered.

### ROOT CAUSE
A **paging address-translation bug** in the seg-load's 2nd memory read, **not** decode and **not** the
cache. `core.sv`'s `cur_lin` (the linear address fed to the dTLB lookup, whose physical result
`mem_xlate` returns) had only a **single CMPS case** for state `S_LOAD2`:
```
S_LOAD2: cur_lin = dbase_edi+str_edi;     // only the CMPS [EDI] 2nd operand
```
But the bus driver's `S_LOAD2` (`core_bus_driver.svh:50-56`) computes **four** different linear
addresses: BOUND/CMPXCHG8B, far-ptr seg-load (LSS/LFS/LGS), far JMP/CALL indirect, and CMPS. For the
lss's 2nd read the bus driver produced the correct linear `0x2ab61` (`dbase+q_ea+q_w`), but `cur_lin`
produced the stale CMPS address `0x22f2a` (es:edi from the prior string op). So the dTLB was looked up
at the WRONG linear → `mem_xlate` returned the physical for `0x22f2a` → the 2nd read read **0** →
`seg_mem_sel = 0` → null SS → #GP. **Paging-only**, which is exactly why `verify`/`verify-sys`
(flat/identity) never caught it and the bug only bit DOS-Quake's paged go32 runtime.

### The fix (this commit)
Make `cur_lin`'s `S_LOAD2` arm mirror the bus driver's four arms EXACTLY (so the translated linear
always equals the accessed linear). Same class as the `S_STORE` `cur_lin` fix immediately below it.
Inert without paging (`mem_xlate == lin`), so `verify`/`verify-sys` stay byte-identical.

### Evidence chain (the taps that nailed it)
1. Slot DRAM correct (`--watch-write`/`--peek-mem`): SS=`0x8f` at `0x2ab61`, no clobber.
2. Decode correct (`dbg_sl` tap gated on the seg-load decode): `ibuf=66 2e 0f b2`, **`d_w=4`** (32-bit
   — my earlier "16-bit decode" reading was wrong; it came from an `eip`-gated tap catching stale
   non-decode cycles).
3. Exec correct decode-fields (`dbg_ls2`): `q_w=4`, `seg_load_lo=0`, `seg_real=0` — but
   `mem_load_data2 = 0` (2nd-read data zero).
4. The 2nd read goes to the **wrong address** (`S_LOAD2` trace): 1st read `0x2ab5d`→`0x076c` (ok),
   2nd read `0x22f2a`→`0` (should be `0x2ab61`).
5. Same-cycle capture: `q_seg_load=1, dbase=0x26ac0, q_ea=0x409d` ⇒ line 52 must give `0x2ab61`, yet
   `mem_addr=0x22f2a` ⇒ the value came from the **post-stage paging translate** (`mem_xlate`), whose
   dTLB lookup uses `cur_lin` — and `cur_lin` for `S_LOAD2` was the CMPS address. Bug located.

---

## 3. Dead end that was eliminated (do not re-walk)

For most of the prior session the #GP was chased as an **L1/L2 cache-coherence race**. That was wrong:
the caches are **not** instantiated in the SoC runs (`ven_l1d`/`ven_l2` are behind
`+define+VEN_SOC_L2`; the uop-cache behind `+define+VEN_UOPCACHE`; **neither is passed** — the default
`ventium_soc.sv:247 \`ifndef VEN_SOC_L2` muxes the stream straight to the TB mem bus). `verif/l1/
tb_socl1l2.sv` validated the cache in isolation (coherent) but it's off the run path. The real bug was
core-side paging translation. NOTE: "System Bridge" = the L1+cachemap+L2; running the *complete* SoC
still needs `+define+VEN_SOC_L2` (the cur_lin fix is needed regardless — it is core-side).

## 4. Debug infrastructure (what works in the tb_soc build)
- `--watch-write <addr>` / `--peek-mem <addr>` (tb_soc.cpp): mem-bus writes / DRAM hexdump.
- **memory tap + `/* verilator public_flat_rd */`** read via `top->rootp->ventium_soc__DOT__u_core__DOT__<sig>`
  — the robust way to surface internal state (the decisive method here). Must be a *memory* (unpacked
  array), not a scalar, and the metacomment needs spaces. RTL `$display` is suppressed in tb_soc; a
  fresh DPI call from a new always_ff gets pruned.
- `dbg_ibuf` core output (`VEN_DBG_CORE`); `VEN_GPTRACE` retire log.

## 5. Build / run quick-reference
Build: `make -C verif/tb soc VEN_IDE_DISK_HEX=/tmp/quake.disk.hex VL_EXTRA_DEFINES="+define+VEN_IDE_DISK_SECTORS=131040 +define+VEN_IDE_CYLS=130 +define+VEN_RTC_EXTMEM_KB=64512 +define+VEN_SOFTVGA"`
Run: `VEN_SOFTVGA=1 obj_dir_soc/tb_soc --image <bios.bin> --out /dev/null --max-insn N --max-cycles 300000000000 --quiesce 200000000`
(`--max-cycles` must be large; the default 1<<24 stops at ~2.3M insn.)

## 6. Bottom line
- FreeDOS boot: **done, validated** (98/98 + 949/949).
- DOS-Quake null-SS #GP: **fixed** (`cur_lin` S_LOAD2 paging-translation), validated (#GP gone to 15M+
  insn; `verify`/`verify-sys` still green). Cache was a red herring.
- Remaining: confirm Quake renders frames + soak a long clean run.
