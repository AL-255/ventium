<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# L1C_BUG — the hardware-only L1 instruction-fetch corruption (F4 Quake board freeze)

**Status (2026-06-14): WORKED-AROUND (root cause localized to the uop-cache FAST PATH, not yet
bit-pinned).** The robust workaround — route ALL functional-mode fetch through the slow S_FETCH
path (`!uop_hit || !cycle_mode`, `ifdef VEN_UOPCACHE`) — was respun (`_proxyrobust`, WNS
**-0.712@50MHz = +4.3@40MHz**, BETTER timing than the fast-path build since less logic is exercised)
and DEPLOYED, and **FIXES the board**: single-stepping the real auxv loop now gives
`d0 d3 d5 d7 db -> **de** (len 3, correct) -> e1 -> e3 -> (jne) -> d0` and the loop ITERATES
cleanly — no more `db->e1` len-6 derail. So the `0x42->0x82` corruption lives in the **uop-cache
fast path** (the slot-read / predecode-on-fill / IC_BRAM-buffer chain), NOT in `ven_l1d`/the fill
(which S_FETCH also uses and reads CORRECTLY). The exact flipped-bit stage is still not pinned (see
§5 fetch-byte tap) — but the workaround unblocks F4. This doc remains the single source of truth so
future sessions don't re-walk the dead ends. See also the memory note
`f4-board-quake-freeze` and `ven-ps-proxy-board-port`.

---

## 1. One-line statement

On the **KV260 silicon only**, the deployed full-feature bitstream (`KV_FULL_DEFS` =
`VEN_FE_PIPE + VEN_UOPCACHE + VEN_BTB_PIPE + VEN_IC_BRAM + VEN_CACHE_HALF` + `VEN_FP_PIPE/PIPE2 +
VEN_SRT/IDIV/BCD_ITER`, plus `VEN_PS_PROXY + VEN_DBG_CORE`) **mis-fetches one instruction byte**
in user-mode Quake: at `0x080985db` the `mov 0x4(%edx),%eax` (`8b 42 04`) decodes as **length 6,
not 3**, because its modrm byte at `0x080985dc` is read as **`0x82`** (mod=10, disp32) instead of
**`0x42`** (mod=01, disp8). Bits 6 and 7 of that byte are flipped (`0x42 ^ 0x82 = 0xC0`). The
mis-decode runs `db -> e1 -> e4 -> (eb 8b = jmp -0x75) -> 0x08098571`, derailing musl
`__init_libc`'s auxv loop and freezing Quake at **retire 557**.

## 2. Why it is hard: every logical path says `0x42`, silicon says `0x82`

This bug has resisted analysis because **no model reproduces it**:

- **DDR is correct.** `ven_soc_app --quake --peek 0x080985d0` dumps the staged carveout and shows
  `... 8b 42 04 83 c2 08 85 c0 75 eb ...` — byte `0xdc` is `0x42`. So staging + the PS write path
  are right.
- **`ven_l1d`'s read is correct (in analysis).** `0x080985dc` is a 4-byte-aligned, within-line
  read (boff=28, not a cross-line `xline`); `c_rdata = rd_window[28*8 +: 32]` returns line bytes
  28..31 = `42 04 83 c2`. The L1-data read of that word is `0x42` at the low byte.
- **The uop-cache walker decodes `0x42`.** `uopcache.sv` predecodes line `0xc0` from `residual`,
  and `residual[28] = 0x42` -> the `decode` leaf yields len 3.
- **Functional sim NEVER reproduces it.** The `l1axi_kv_proxy` Verilator model (the EXACT deployed
  defines) PASSES retire 557 and runs to a syscall; full-cache (`VEN_L1_SETS=128`) sim too. `make
  verify` is functionally GREEN.

Yet the **board** (the only ground truth) reads `0x82`, **deterministically**, **identically at
30 MHz and 40 MHz** (clock-independent), and **stably under single-step**. That combination —
deterministic + clock-independent + hardware-only + a clean two-bit flip on one byte — points at
a **physical/structural effect the RTL sim cannot model**:
- a **BRAM read-during-write (RAW)** collision on the IC_BRAM / uop-cache-slot / pf_line_buf BRAM
  (Verilator models a defined RAW; the inferred RAMB36 may differ: `READ_FIRST`/`WRITE_FIRST`/
  `NO_CHANGE`), or
- an **uncovered timing path** (a multicycle/false-path constraint that is actually real; a
  *setup* fail would ease at 30 MHz — it does not, so a hold/RAW or a path that fails at both
  clocks), or
- **X-propagation / uninitialised-read** the FPGA resolves to a real (wrong) value where
  Verilator resolves to 0, or
- a **`VEN_CACHE_HALF` geometry interaction** (recent: the half cache was added for K26 timing;
  idx=6/tag=21 vs the default idx=7/tag=20).

The two-bit flip is in the **mod field** of a modrm — the most damaging single byte to corrupt
(it changes the instruction length), which is why it surfaces as a control-flow derail.

## 3. Reproduce it on the board (no respin needed)

Tooling already in `ven_soc_app` (commits: `--peek` e75151a; `--bp/--steps` 2b3bb4b;
`--poke`/`--flush-each-step` THIS session, uncommitted):

```sh
# board: ubuntu@10.0.0.4, sudo pw "Andy1998$", clock 40MHz (/tmp/venclk.sh set 25)
# single-step the REAL auxv loop -> watch db (step) jump db->e1 (len 6) then derail to 0x08098571:
ven_soc_app --quake /tmp/image_board.json --brk 0x87c3000 --bp 0x080985d0 --steps 30
#   d0 d3 d5 d7 db -> e1 -> e4 -> 08098571 -> S_HALT     (the bug)

# --poke writes the carveout directly (PS mmaps DDR); --flush-each-step pulses FLUSH_REQ:
ven_soc_app --quake ... --poke 0x080985d0 <hexbytes> --bp 0x080985d0 --steps N --flush-each-step
```

`--peek <gaddr>` confirms DDR; the **single-step EIP delta = the decoded length** is the oracle.

## 4. What it is NOT (ruled-out dead ends — do not re-walk)

1. **Not staging / DDR.** `--peek` = `0x42`.
2. **Not the slow path.** EARLY note said "board uses the slow path" — WRONG. The board runs the
   FAST path (FE_PIPE/UOPCACHE/IC_BRAM); FSM `0x17` = `S_PIPE` (recount the state enum with the
   ACTUAL defines: `VEN_TRANSCENDENTAL` is OFF, shifting numbering down 1).
3. **Not the AXI master burst.** Built a PS8-VIP xsim harness (`fpga/scripts/sim_l1axi_vip.tcl`,
   `verif/l1/tb_l1axi_vip.sv`): `ven_axi_master` issues a protocol-clean line-fill
   `AR addr=0x00480985c0 len=7 size=2 burst=1`, ACCEPTED by the VIP with NO protocol assertion.
   (Harness caveats: needed `force shutdown=0` — bd_l1axi.tcl leaves it undriven; and an
   xsim-portability refactor of `ven_l1d.sv:146` to a named `rd_window` temp since xsim can't
   index a concat. The PS8 VIP HPC0 slave didn't return RVALID for reads — a VIP-init limit, not
   a DUT bug. The harness tests `ven_l1d`+`ven_axi_master`, NOT the core icache.)
4. **Not the `uop_hit` predecode-valid gate.** That WAS a real bug (`uop_hit`/`uc_v_avail`
   computed at core.sv:3462 but consumed NOWHERE — the promised "S_PIPE !uop_ready arm" was never
   wired, added dead in commit 4cdf7eb). Wiring it (core_fastpath.svh: `else if (!uop_hit) ->
   S_FETCH`) + the walker straddle-end fix (uopcache.sv: only record a boundary when
   `woff+pd_len <= IC_LINE`) cut the +UOPCACHE+IC_BRAM **func** verify **60 -> 28 -> still 28**
   fails and made the board free-run no longer HALT at 557 — BUT the on-silicon single-step shows
   `db` STILL decodes len 6 (the IDENTICAL pre-fix derail). So `db` is the `uop_hit=1` class (the
   predecode marked a valid boundary, the SLOT is just wrong) — the deeper corruption, untouched.
5. **Not reproducible in ANY Verilator sim** (see §2).

## 5. Diagnostic gap (why it's slow to pin)

`VEN_DBG_CORE` taps (EIP / retire / PC-ring / perf) **only latch valid state when the core is
HALTED** (the single-step/breakpoint path). In **free-run** they read `0` / empty / `halted=1` —
UNRELIABLE. So:
- The only committed-state oracle is **single-step** (`--bp/--steps`), which can show EIP deltas
  but **NOT the fetched bytes**.
- Free-run progress is only observable via **PS-counted** `syscalls` / `frames` (both 0 = Quake
  never reaches file-I/O) and the VGA dump (which is leftover garbage; Quake renders to a
  framebuffer, not 0xB8000).

**The decisive missing instrument:** an on-die **fetch-byte tap** — expose `ic_byte(flin+0..5)`
(the 6 raw icache bytes at the fetch pointer) as 2 `ven_soc_axil` dbg registers (wire
core.sv -> ventium_kv260_core.sv -> ven_soc_dbg.sv -> ven_soc_axil.sv, mirroring the `dbg_eip`
chain). Respin, single-step to `db`, read the 6 bytes:
- **byte1 == `0x82`** -> the **icache/fill** holds the corrupt byte (look at IC_BRAM fill / the
  RAMB RAW / the half-cache fill addressing).
- **byte1 == `0x42`** -> the icache is fine, the **uop-cache SLOT read** (or its BRAM) corrupts it.

## 6. Fixes / workarounds tried (this session)

| change | where | effect |
|---|---|---|
| wire the dead `uop_hit` gate | `core_fastpath.svh` (`ifdef VEN_UOPCACHE`) | +UOPCACHE func 60->28; default 77/77 byte-identical; board no longer halts@557 but `db` still len 6 |
| walker straddle-end boundary suppress | `uopcache.sv` W_WALK (`woff+pd_len<=IC_LINE`) | no change to the 28 (they're not straddle-end) |
| **robust: func-mode -> S_FETCH** | `core_fastpath.svh` (`!uop_hit \|\| !cycle_mode`) | **+UOPCACHE func 28->0 (GREEN)**; default 77/77; **RESPINNING (`_proxyrobust`)** — bypasses the uop-cache fast path at runtime in func mode (board = cycle_mode=0) while keeping the uop-cache HARDWARE (the 32:1 MUXF stay deleted -> congestion/timing unchanged). FIXES the board IFF the corruption is in the fast path; if `db` still derails, it localizes the corruption to `ven_l1d`/the fill (which S_FETCH also uses). |

All three are `ifdef VEN_UOPCACHE` / in `uopcache.sv`, so the **default `make verify` is
byte/cycle-identical** (the hard constraint).

## 7. Respin facts

- Driver: `FE_PIPE=1 UOPCACHE=1 BTB_PIPE=1 DBG_CORE=1 PS_PROXY=1 OUTTAG=_proxyrobust
  vivado -mode batch -source fpga/scripts/impl_kv260_soc.tcl`.
- This design is **congestion-bound** (half-cache + uop-cache + L1AXI): a respin takes **~1.5–2 h**
  of routing. WNS lands ~`-3.0 ns @ 50 MHz target = +2.0 ns @ 40 MHz` (the sign-off point); hold
  met. Dropping `VEN_UOPCACHE` is NOT an option — it re-introduces the 32:1 byte-select MUXF wall
  and won't route (confirmed by the maintainer).
- Deploy: `bootgen -arch zynqmp -process_bitstream bin -image <bif> -w` -> `.bit.bin`; scp to
  `/lib/firmware/xilinx/ventium/ventium.bit.bin`; `xmutil unloadapp; xmutil loadapp ventium`;
  `venclk.sh set 25` (40 MHz). Backups on the board: `ventium.bit.bin.pre*.bak`.

## 7b. AFTER the fetch fix: a SECOND blocker — a data-path string-scan livelock

With `_proxyrobust` deployed the FETCH is correct (auxv loop iterates), and the core PROGRESSES
past it to a `strrchr`-style loop at **`0x08098630`** (`cmp al,'/'` / `mov al,[ebx]` / `inc ebx` /
`test al,al` / `jne 30`). On silicon this loop **LIVELOCKS**: 96+ single-step iterations, `al` is
NEVER `/` (the `mov [edx],ebx` at 0x08098634 never runs) and NEVER null. Free-run = **0 syscalls /
0 frames in 140s** (a finite scan would exit in <1s and reach the first `int 0x80`). So the
**data load `mov al,[ebx]` reads bytes that never terminate** — a SECOND corruption, on the DATA
path this time (the robust fetch fix doesn't touch loads). The kvproxy SIM passes this loop (same
image -> reaches a syscall), so it's BOARD-SPECIFIC, NOT a staging/image bug. Candidates:
(a) `ebx` is wrong — corrupted by an earlier DATA load/store in the auxv loop (e.g. the
    `mov (%edx),%ecx` @d5 or `mov %ecx,0x18(%esp,%eax,4)` @d7) reading/writing wrong bytes, so the
    AT_EXECFN pointer pulled into ebx is garbage; or
(b) a `ven_l1d` BYTE-load corruption at this address/access pattern (note FreeDOS data-reads WORK,
    so it is NOT a broad ven_l1d break — likely high-addr / unaligned / byte-specific).
DIAGNOSTIC: the VEN_DBG dump shows only EIP/CS/ESP/EFLAGS — NOT ebx/eax/ecx/al. To see the loaded
bytes + ebx needs a respin adding GPR taps (or reuse the syscall-window gpr capture). Pair it with
the §5 fetch-byte tap (now repurpose for DATA: expose the load's c_addr + c_rdata at the dbg halt).

## 7c. The userspace path then hit a THIRD wall (ven_l1d DATA staleness) — TRACK PAUSED

After the fetch fix + progress past the auxv loop, the core reaches a `strrchr(argv[0],'/')` at
`0x08098630` that LIVELOCKS. PS-tested (no respin): poking `"/A\0"` at argv[0] (`0x40c34a8b`) +
`--flush-each-step` makes the scan run perfectly and EXIT (`->0x0809863d`, ESP changes) -> **`ebx`
is CORRECT** and the load reads right WITH a flush. Without flush the loads read STALE `ven_l1d`
data (the long real argv[0] `/home/yukidama/github/ventium/...` has many '/', the board finds
ZERO). A fresh-reset run also fails -> it's **during-run** staleness, not cross-invocation. So
`ven_l1d` (the unified L1, fetch+data in mode 2) serves a STALE line for the freshly-staged string
region; a per-load FLUSH_REQ fixes it. Root cause not pinned (the PS stages DDR with no L1 snoop;
or a half-cache set-aliasing fill). A periodic-FLUSH_REQ PS workaround in the proxy service loop is
viable (FLUSH_REQ works mid-free-run, no halt). **DECISION (user, 2026-06-14): PIVOT to the DOS
Quake path** (real-mode / sys_mode -> slow S_FETCH) which sidesteps BOTH the fast-path fetch bug AND
this user-mode data-staleness. The userspace track is PAUSED here, fully diagnosed, ready to resume.

## 8. Next steps (in priority order)

1. **Board-test the `_proxyrobust` bitstream** (respin in flight). If Quake clears `db` and
   produces P5Q1 frames -> the corruption was in the uop-cache fast path; F4 done (slow but
   correct). If `db` still derails -> the corruption is in `ven_l1d`/the IC_BRAM fill -> go to (2).
2. **Add the on-die fetch-byte tap** (§5) -> respin -> read the bytes at `db` -> pin icache-fill
   vs slot. THE definitive diagnostic.
3. With the stage pinned, inspect that BRAM's inferred RAW mode / the fill addressing / a hold or
   uncovered-path constraint on that net; add an XDC/RTL fix; re-verify (default byte-identical) +
   respin.

## 9. ROOT-CAUSED + FIXED (2026-06-14): ven_l1d had no WRITE-ALLOCATE → posted-write incoherency

The `_proxyrobust` bitstream (robust func→S_FETCH fetch fix) cleared the fetch corruption: userspace
Quake now runs **37.9M** instructions (vs 557) — but with **0 syscalls**, derailing onto a wrong path
that wedges at a `memcpy` `ret` (S_HALT). Single-step from entry runs CORRECTLY (reaches the
`__init_libc` envp loop); only FREE-RUN derails → a free-run-only timing bug, NOT a fetch/decode bug.

**Two bugs found, both PS/sim-confirmed before respin:**

(a) **Sim-fidelity gap (TB only).** The Verilator TB's `MemModel` did not fold guest addresses into
    the 256 MiB carveout the way the board's `mem_carveout.cpp` (`addr & 0x0FFFFFFF`) and the L1AXI
    master (REMAP + ADDR_MASK) do. The image loader + int-0x80 emulator used RAW guest addresses while
    the core used MASKED ones, so for the user stack at `0x40c3_xxxx` (≥ 0x1000_0000) they diverged:
    `set_thread_area` read a zero `user_desc`, never allocated entry 6, glibc loaded `%gs=0xfffb`
    (flat), and `call *%gs:0x10` (the AT_SYSINFO `__kernel_vsyscall` gate) jumped to NULL.
    FIX: `verif/tb/memmodel.cpp` now folds (`& 0x0FFFFFFF`) under `VEN_KV260_SOC && VEN_PS_PROXY`,
    matching the board. The board was already correct here.

(b) **THE BOARD BUG — ven_l1d has no write-allocate.** A write MISS goes write-through ONLY (no
    line allocate). On real silicon the PL→smartconnect→DDR write is POSTED (BVALID precedes global
    visibility), so a later read MISS of the same line fills from not-yet-committed DRAM → STALE data.
    `__init_libc`'s `rep stos` zeroes an *uncached* buffer then reads it back a few instructions
    later → garbage → wrong branch → 0-syscall derail. Single-step drains the posted write between
    instructions, hiding it; the coherent TB (write visible at the W beat) hid it too.
    SIM REPRO: added `AXI_WPOST` to the TB AXI slave (BVALID early, backing update deferred N clocks).
    `AXI_WPOST>=40` reproduces the board EXACTLY (0 syscalls, gs=0xfffb, jump-to-NULL).
    FIX: `rtl/mem/ven_l1d.sv` — a within-line write MISS now WRITE-ALLOCATES (fills the line into the
    not-MRU victim, holds `c_ack=0`, then the retry hits → RMW + write-through), so reads hit the
    cached copy regardless of DDR posting. Comb write-through + `c_ack` gated on `hit || xline`.
    VALIDATED: `AXI_WPOST=0..200` all run clean (gs=0x33); end-to-end WPOST=100 runs Quake to the
    SAME 4.09M-insn / 24-syscall / "Couldn't load gfx/palette.lmp" point as the coherent run. Gates:
    make verify 77/77 byte-identical, L1D/L1AXI/XWORD/XLINE/CALLRET/WD all OK. Respin OUTTAG=proxywa
    (FE_PIPE=1 PS_PROXY=1 DBG_CORE=1) in flight; board retest pending.

Remaining (post-respin, PS-software): "Couldn't load gfx/palette.lmp" — the int-0x80 emulator opens
pak0.pak + reads the header (Quake prints "Playing shareware version") but fails to load that lump.
FIXED PS-side: added a VEN_QUAKE_DATA env redirect in syscall_emu.cpp open() ("/opt/quake/id1/.." ->
$VEN_QUAKE_DATA/id1/..), since the image was produced with -basedir /opt/quake which does not exist on
host/board. With it the SIM now loads pak0.pak (339 files), passes palette.lmp, reaches "875k surface
cache / Initializing palettes..." cleanly (63 syscalls) — the userspace path is FULLY CORRECT IN SIM.

## 10. BOARD RETEST of the write-allocate respin (proxywa) — DID NOT FIX THE BOARD (2026-06-14)

Built+deployed the write-allocate bitstream (OUTTAG=proxywa; md5 765da913 confirmed loaded, != the
robust .prewa.bak; WHS=+0.011 hold MET, WNS=-2.242@50MHz => +2.76@40MHz so timing MET at the 40MHz
operating point). Ran userspace `--quake` (VEN_QUAKE_DATA=/tmp/quake, new aarch64 ven_soc_app with the
redirect): **IDENTICAL derail — 0 syscalls, retire=37.9M, wedge @0x080a67e4 (memcpy).** So the
AXI_WPOST sim repro was a SAME-SYMPTOM-DIFFERENT-MECHANISM false lead: write-allocate fixes the
posted-write hole (real, kept — sim-validated, gates green) but is NOT the board bug.

BOARD BUG NOW PRECISELY LOCALIZED (breakpoint bisection on silicon):
- Free-run is CORRECT through the `rep stos` (write-allocate region — so NOT a write bug) and REACHES
  the envp loop @0x080985a8 (HW bp FIRES; PC-ring trail clean; ESP=0x40c34700 == sim n=105). So the
  write path + the early reads are fine.
- Free-run does NOT reach set_thread_area's int-0x80 @0x080aebdb (0 syscalls). So it diverges in the
  AUXV-region READS, n~105..1454 (between the envp loop and __set_thread_area).
- Single-step from entry runs CORRECTLY through this same region (reaches 0x080985a8 at step 219). So
  it is a FREE-RUN-ONLY READ-PATH bug.
- NOT timing (met at 40MHz; memory note: clock-independent 40==30MHz), NOT write-allocate, NOT
  reproducible in the cycle-accurate Verilator sim (clean — runs Quake to video init), NOT reproduced
  by uniform AXI_RLAT/AXI_WLAT/AXI_WPOST. Strongly suggests a STRICT-AXI R-beat / BRAM-read /
  uncovered-path issue in the L1 line-fill (ven_axi_master R-channel or ven_l1d async read) that the
  real PS-DDR/smartconnect timing exposes but the lenient behavioral sim slave tolerates.

DIVERGENCE FURTHER NARROWED (more bp bisection): free-run REACHES the argv[0]-basename scan loop
@0x08098630-b (the "strrchr" — `cmp $0x2f,%al; jne; mov %ebx,(%edx); mov (%ebx),%al; inc %ebx; test;
jne`) and executes the slash-store 0x08098634 on the first iteration (ESP=0x40c34700 == sim). So it
diverges WHILE scanning argv[0] (a later byte/line) or in the immediately-following __init_tls
(0x08098641) -> __set_thread_area path. This IS the summary's "strrchr @0x08098630 livelock /
ven_l1d data-staleness": single-step + --flush-each-step reads argv[0] correctly; free-run reads it
STALE. argv[0] string is at ~0x40c34a8b (a stack/data line first touched cold at the scan).

PERIODIC-FLUSH PS WORKAROUND FAILED (VEN_QUAKE_FLUSH_N): pulsing CTRL.FLUSH_REQ every N service-loop
iterations gives **retire=0 for ALL N (1,8,64,512,4096)** — the `wr(CTRL, CORE_RUN|FLUSH_REQ)` write
BREAKS the running core on silicon (resets/stalls it). SECONDARY FINDING: the board's CTRL-write flush
path is itself untested+broken (0 syscalls on the board means the syscall-path flush at ven_soc_app.c
:577 never ran either; the sim pulses flush_all directly, not via the CTRL reg, so it was never caught).
So a flush-based workaround is out. Knob reverted.

NEXT (the cheap PS tests are now exhausted — sim clean, L1-VIP clean, latency/WPOST/flush all tried):
ON-DIE TAP RESPIN is justified. Add to the VEN_DBG_CORE unit (a) committed-GPR exposure (R_DBG_EAX..
EDI) so a bp dump shows the loaded values, and (b) a RETIRE-COUNT breakpoint (halt when retired==N) so
free-run can be stopped EXACTLY at the divergence (n~1000+) — the PC bp can't, because the scan is a
loop (first-reach fires on the correct early iteration). Then halt at the divergent n, compare GPRs +
(ideally) an L1-read ring to the sim, pin the wrong read. Implement carefully, validate via the sim
build + make verify (default byte-identical), THEN respin. ALT: full-core PS8 AXI VIP (no respin, but a
large xsim build). The write-allocate fix + VEN_QUAKE_DATA redirect STAY (both correct, sim-validated).

## 11. ROOT CAUSE CONFIRMED (2026-06-14): silicon-timing on the high-fanout L1 async-read path

Two converging no-respin proofs:
1. Directed xline-READ gate test (verif/l1/tb_l1_axi.sv [3b], commit 5fffb45): the cross-line 4-byte
   read (cold next-line fill + both-resident hit) — the argv[0] byte-scan pattern — is FUNCTIONALLY
   CORRECT. So the board derail is NOT a logic bug; it is a timing/silicon effect invisible to the
   cycle-accurate Verilator.
2. proxywa impl reports: the WNS setup path (-2.242ns @50MHz = +2.76 @40MHz, "met" but marginal,
   **49 logic levels**) is `u_core/eip_reg -> ... u_l1axi/u_l1d/dc_line_reg async read ... -> gpr_reg`.
   physopt could NOT optimize the `u_l1d/dc_line` read-data nets — **fanout 1152..1460**, unreplicable
   (RAMD64E LUTRAM outputs). So ven_l1d's wide ASYNC distributed-RAM read (256b line read + the
   512->32 byte/way mux) is the dominant, high-fanout, deep combinational path. At 40MHz it "meets" in
   STA but is silicon-marginal; the deep argv[0] byte-scan (cold fills + xline reads) trips it free-run
   (back-to-back), while single-step (drains between insns) and Verilator (no gate delay) do not.

THE FIX (next iteration, careful): break this path — REGISTER/PIPELINE the ven_l1d read (async
distributed-RAM read -> 1-cycle synchronous read), so the LUTRAM read + the wide mux are in separate
cycles and the registered output has manageable fanout. Cost: L1 read becomes 1-cycle latency; the
core already polls c_ack (handles multi-cycle), so functional correctness holds, but the cycle-mode
(M5) bands shift -> re-tune or gate the sync read behind a define used only for the board (functional)
bitstream. Validate: l1d/l1axi gates + make verify, then respin + board retest. Lower-risk alt to
investigate first: cut the read fanout via smaller/direct-mapped L1 (define knob) — may relax timing
without a read-contract change. Either way this is now a TIMING-CLOSURE fix, not a logic fix.
