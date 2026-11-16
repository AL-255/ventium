# System-Mode Differential & Witness Verification (`verif/sys/`)

`verif/sys/` validates Ventium's privileged and system architecture across real mode, 16/32-bit protected mode, 4 KiB and 4 MiB PSE paging, Virtual-8086 (`V86`) mode, CPL0–CPL3 rings, task switches, call/interrupt/trap gates, cross-page fragment execution, debug registers, System Management Mode (`SMM`/`RSM`), and system x87 state (`docs/m2s-system-spec.md`, `docs/trace-format.md` §2.4).

## Primary Make Targets

| Make Target | Runner | Scope |
| --- | --- | --- |
| `make verify-sys` | `verif/sys/run-sys-golden.sh` (+ dedicated witness runners) | Runs the bare-metal 64 KiB `-bios` corpus (`F000:FFF0` reset) through `qemu-system-i386` (`gen_trace.py --system`) and `tb_ventium --system`, comparing `cr0..cr4`, selectors, `eflags`, `eip`, and all GPRs per retired instruction (plus SDM self-checks where QEMU 8.2.2 softmmu lacks fidelity). |
| `make verify-sys-fpreloc`<br>`make verify-sys-fpload`<br>`make verify-sys-faststore`<br>`make verify-sys-faststack`<br>`make verify-sys-faststack-seg` | `run-sysfpreloc-gate.sh`<br>`run-sysfpload-gate.sh`<br>`run-pfaststore-gate.sh`<br>`run-pfaststack-gate.sh`<br>`run-pfaststackseg-gate.sh` | System fast-pipeline (`S_PIPE`, `cycle_mode=1`) acceptance gates: relocated equal-nonzero-base clients, flat/bounded fast loads & stores, precise `CR0.WP` `#PF` store restart, CPL3 `PUSH`/`POP` `#PF` retry under delayed backing ACKs, and full-limit expand-down `#SS(0)` precision. |
| `make a20` / `seg` / `intlim` / `tsslim` / `retfsel` / `callsel` / `xc04` / `unimpl` / `retfout` / `callxpl` / `mtype` / `icbypass` / `ioperm` | `verif/sys/run-*-gate.sh` | Standalone architectural gates included in `make verify-all`: port `0x92` A20 wrap, `+VEN_SEG_ENFORCE` limit checks, IDT gate CS-limit delivery, truncated-TSS `#TS`, far `CALL`/`RETF` selector & outer-privilege stack switches, 6-producer page-crossing fragment engine (`xc04`), physical memory-type & `CR0.CD` fetch cacheability, and multi-port TSS I/O permission bitmaps. |
| `make fenv` / `fpstore` / `x87stk` / `x87trap` / `x87depop` / `x87debug` | `verif/sys/run-*` | System x87 gates: `FNSTENV` exception masking, writable destination probe before `FISTP` pop, 7×2 `#IS` stack-fault matrix across functional/cycle/`FP_PIPE`/`FP_PIPE2` builds, strict `#NM > #MF` fast-path bailout (`VEN_X87_MF_STRICT`), masked `DE` arithmetic-and-pop tag/QNaN commit, and post-commit `TF`/successor-`#DB` retirement. |
| `make docs-status` | `verif/sys/run-docs-status-gate.sh` | Verifies consistency between `docs/unsupported-isa.md`, `rtl/core/` loud-halt tags (`0xD*`), `KV_FULL_DEFS`, `run-verify-all.sh` pin classes, and manifest masks/statuses. |

## Building `qemu-system-i386` & Running a System Test

```sh
bash verif/sys/build-qemu-system.sh          # out-of-tree i386-softmmu build in ventium-refs/.../build-sys/
bash verif/sys/run-sys-golden.sh pmode       # build pmode.bin, run QEMU golden + RTL --system, diff
```

- **Oracle Transport & `anchor_tail`:** `gen_trace.py --system` launches `qemu-system-i386 -machine pc -m 32 -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios <image>` over an authenticated private Unix socket (`owned_gdb.py`), aligns QEMU's 344-byte `i386-softmmu` `g`-packet (`cr0..cr4` at offset 76, `st0..fop` at offset 100), and queries `monitor info registers` for exact hidden `CS.base` when collecting instruction bytes.
- **Partial-Oracle & SDM-Witness Stages:** Where QEMU 8.2.2 softmmu omits P5 checks — per-access segment limits (`seg`, `pintslim`, `pfaststackseg`), null data-segment `#GP(0)` (`pnullseg`), return-`EIP` CS limits (`piretgp0`), `FNSTENV` exception masking (`fenv`), x87 stack faults (`x87stk`), or `SMM`/`RSM` (QEMU's gdbstub single-step masks `SMI#` and writes the P6 save-state map rather than P5's `SMBASE+0xFE00` layout; see [`tests/psmm/README.md`](tests/psmm/README.md)) — gates never fabricate goldens or weaken masks. Instead, they grade explicit in-guest fault-frame/register witnesses, `+ven_faultlog` vectors, and `--smm-dump` physical-memory readbacks.

## Directed Regression Harnesses in `verif/sys/`

In addition to `verif/sys/tests/*/`, the subdirectories below retain focused recipe/regression harnesses from October 2026 ISA/x87 bring-up whose RTL repairs are integrated into the board-qualified `c0e3fe43` hardware profile (enabling cold FreeDOS Doom, DOS Quake, and Windows 95 OSR2):

| Subdirectory | Covered Architectural Contract |
| --- | --- |
| `smsw_memory/` | `0F 01 /4` memory `SMSW r/m16` always writes 16-bit `CR0[15:0]` via `S_STORE` across real/CPL0/CPL3/V86, 16/32-bit operand/address sizes, split-page `#PF` repair/retry (`CR0.WP=1`), and Intel-spec `LOCK`/segment denials. |
| `lmsw/` | `0F 01 /6` `LMSW r/m16` CPL0 serialized `CR0[3:0]` update with sticky `CR0.PE` (`(old_cr0 & ~0xF) \| (src & 0xF) \| (old_cr0 & 1)`), 2-byte memory source width, and split-page `#PF` retry. |
| `obsolete_fp/` | Pentium 8087/287 compatibility no-ops `FENI` (`DB E0`), `FDISI` (`DB E1`), and `FSETPM` (`DB E4`): check `CR0.EM`/`TS` (`#NM`) and reject `LOCK` (`#UD`), without polling pending `#MF` or mutating x87 state/FIP. |
| `fp_env_restore/` & `fp_env_store/` | All four 14/28-byte protected and real/V86 (`seg_real`) x87 environment pointer layouts (Intel Vol. 3 Figs. 6-6..6-9) for `FLDENV`/`FRSTOR`/`FNSTENV`/`FNSAVE`, plus `d_f_mem_write=1` write-permission pre-probes so read-only destination `#PF`s fault before `FNSTENV` masks exceptions or `FNSAVE` resets the FPU. |
| `frndint/` | `FRNDINT` (`D9 FC`) extended-precision integer reconstruction (obeys `RC`, ignores `PC24`/`PC53`), unsigned magnitude near `2^63`, exact/inexact `C1` commit, and masked/unmasked `IE`/`DE` operand preservation. |

## Safeguards

- Always pass a private `TB_BIN` / `OBJDIR` when running variant system gates (`VEN_SEG_ENFORCE`, `VEN_X87_MF_STRICT`, `l1axi_kv_full`); never clobber `verif/tb/obj_dir/tb_ventium`.
- Place new scratch outputs under `/home/yukidama/external/tmp` with explicit `TMPDIR`, and remember that `--l1-axi` and `--cycle` / `--cycle-func` (`cycle_mode=1`) must be passed explicitly for hardware-profile acceptance runs.
