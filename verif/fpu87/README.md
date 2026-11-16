<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
     SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# `verif/fpu87/` — Dual-Oracle Randomized & Corner-Case x87 Suite

`verif/fpu87/` exercises 80-bit extended-precision (`extF80`) x87 instructions across dense corner cases (normals, subnormals, signed zeros, `±Inf`, `QNaN`/`SNaN` payloads, real indefinite, and TestFloat vectors) and all four IEEE-754 rounding modes, triangulating Ventium RTL against **two independent references**:

```text
        Berkeley SoftFloat-3e (extF80, 8086-SSE)
                  |  xcheck.py (st0 value triangulation)
                  v
            Pinned QEMU 8.2.2  ───────────────►  Ventium RTL (Verilator)
                        compare.py --mode func (st0..st7, fctrl, fstat, ftag)
```

1. **`compare.py` (Differential Authority):** Checks full architectural x87 state (`st0..st7`, `fctrl`, `fstat`, `ftag`) against the pinned QEMU Pentium golden (`--x87`).
2. **`xcheck.py` (Independent Triangulation):** Cross-checks QEMU's `st0` against Berkeley SoftFloat-3e (`oracle/ven_fpu_oracle.c`) for arithmetic/conversions and `qref` (`tools/p5xtrans/qref.c`) for transcendentals, immediately isolating true RTL bugs from QEMU 8.2.2 SoftFloat quirks (such as `C1` roundup bits, `FPREM1` quotient flags, or `FRNDINT` `PC` leaks; see `../qemu-trace/README.md`).

> **Third-Party Boundary:** `verif/fpu87/extern/` vendors upstream Berkeley SoftFloat-3e and TestFloat-3e (John R. Hauser, UC Berkeley). **Never edit files inside `extern/`.** `Makefile` builds SoftFloat's `8086-SSE` specialization (`s_propagateNaNExtF80UI.c` is byte-identical to `8086` for `extF80`).

## Running

```sh
bash verif/fpu87/run-fpu87-gate.sh [smoke|default|thorough] [seed]
```

Environment overrides:
- `FPU87_OPS=add,div` — restrict tested operation families
- `NO_TRANS=1` — skip transcendental generation
- `NO_TESTFLOAT=1` / `TF_LEVEL=2` — disable or deepen `testfloat_gen` vectors
- `FPU87_JOBS=N` — worker parallelism

Build oracle components standalone:

```sh
make -C verif/fpu87            # build SoftFloat-3e + oracle/ven_fpu_oracle
make -C verif/fpu87 testfloat  # build TestFloat-3e generator
make -C verif/fpu87 qref       # build tools/p5xtrans/qref transcendental reference
```

## Coverage & Hardware FPU Relationship

| Group | Operations | Triangulation Oracle |
| --- | --- | --- |
| **Core Arithmetic & Sign** | `add`, `sub`, `mul`, `div`, `sqrt`, `abs`, `chs` | Berkeley SoftFloat-3e (`extF80`) |
| **Rounding / Remainder / Scale** | `rndint`, `rem`, `rem1`, `scale` | SoftFloat-3e + dedicated `verif/srt/` & `verif/sys/frndint/` exact integer oracles |
| **Comparisons** | `fucom` (+ `verif/fp_compare/` invalid-op sweeps) | QEMU + Intel SDM NaN/status rules |
| **Transcendentals** | `f2xm1`, `fyl2x`, `fyl2xp1`, `fpatan` (+ trig in `verif/trsc/`) | `qref` (`tools/p5xtrans/qref.c`) |

Operands are loaded with raw `fldt` (`tbyte`), delivering denormals, `SNaN`s, and unsupported `floatx80` encodings (`unsup` informational pool: pseudo-denormal, unnormal, pseudo-Inf, pseudo-NaN) directly to the FPU without format-conversion normalization.

### Legacy Default Core vs Deployed Shared FPU (`fp_shared/`)

- Early runs of `fpu87` against the June 2026 legacy `rtl/fpu/` datapath surfaced directed-rounding overflow inversions, denormal `FDIV` overflow, `FRNDINT` subnormal/C1 bugs, and unimplemented `FPREM`.
- In the deployed hardware architecture (`c0e3fe43` on `main`, `VEN_FP_SHARED` + `VEN_FP_SHARED_DIRECT` + `VEN_SRT_ITER` + `VEN_TRANSCENDENTAL` + `VEN_FPREM`), **`fp_shared/ven_fp_top.sv` (`u_fp_shared`)** and **`rtl/fpu/fpu_srt_div.sv` (`u_srt`)** implement IEEE-754 directed-rounding overflow (`±Inf` vs `±max_norm`), normalized subnormal `FDIV`/`FSQRT`/`FPREM`/`FPREM1` with `UM=0` underflow scaling (`verif/srt/`), `PC`-independent `FRNDINT` (`verif/sys/frndint/`), and pipelined `ven_fp_alu` / `ven_fp_trans` (`fp_shared/tb/`, `verif/fppipe/`, `verif/trsc/`).

## Files

| Path | Role |
| --- | --- |
| `oracle/ven_fpu_oracle.c` | SoftFloat-3e `extF80` batch/single oracle |
| `gen_fpu87.py` | Generates `.s` programs, `manifest.json`, and oracle expectations under gitignored `build/` |
| `xcheck.py` | Compares QEMU golden `st0` against SoftFloat/`qref` |
| `run-fpu87-gate.sh` / `fpu87_worker.sh` | Parallel build, trace, `compare.py`, and `xcheck.py` runners |
| `extern/` | Vendored SoftFloat-3e & TestFloat-3e submodules (**do not modify**) |
