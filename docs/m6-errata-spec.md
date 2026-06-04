# M6 — errata / stepping fidelity spec (layer-5 stretch)

M6 (PLAN §7, REF.md layer 5) reproduces documented **P5 silicon errata** in the
RTL. This is explicitly a **partial, mostly-non-differential** milestone — see the
oracle problem below — scoped to the errata that have **deterministic, self-
checkable** behavior a user-mode functional+cycle model can reproduce.

## The oracle problem (why M6 is different)

QEMU `-cpu pentium` computes **correctly** — it does NOT reproduce P5 silicon
bugs. So there is **no differential oracle** for errata: we cannot diff a "buggy"
RTL against QEMU (QEMU is the *correct* answer). Instead, errata are verified
against the **documented behavior** in the spec updates
(`ventium-refs/01-intel-canonical/pentium-spec-update-242480-022.pdf`,
`242480-041_…1999.pdf`) via **targeted self-checking tests** that assert the
documented buggy result occurs.

**Hard design rule — errata are SELECTABLE, default OFF:**
The clean core (M0–M5) must stay green. Errata live behind a **stepping/config
input** (e.g. `errata_en` bits, or a `STEPPING` parameter). With errata **off**
(default), `make verify` stays fully GREEN (QEMU-matching). With a "buggy P54C
stepping" **on**, the errata self-check suite (`make m6`) asserts the documented
defects. We reproduce the bug behind a flag; we never make the default core wrong.

## Verifiable errata (in scope — reproduce + self-check vs documented cases)

1. **FDIV / SRT divide flaw — Erratum 23 (242480-022 printed p.78).** The iconic
   one: 5 missing PLA entries in the radix-4 SRT divider → specific divisors yield
   a quotient wrong at ~the 13th significant binary digit. Affects FDIV/FDIVP/
   FDIVR/FDIVRP/FIDIV/FIDIVR and the divide-dependent FPREM/FPREM1/FPTAN/FPATAN.
   *Reproduce:* model the SRT flaw (preferred — reproduces ALL affected operands)
   OR, if the exact PLA model is impractical, reproduce the published failing
   operands. *Self-check:* assert the documented wrong quotient for known failing
   pairs (e.g. 4195835.0/3145727.0 → the flawed result, not 1.333820449…; plus
   other published vectors). Default stepping = correct (matches M3/QEMU).
   **As built:** the SRT-flaw *model* path is not faithfully verifiable (Intel
   never published per-operand reduced-precision bits and QEMU is correct → no
   oracle), so we took the explicit fallback — *reproduce the published failing
   operand* (the one canonical pair, the only public vector with a bit-exact
   flawed double) — and deliberately do NOT fabricate a quotient for any other
   triggering divisor. Negative-control self-checks confirm no fabrication.

2. **FIST/FISTP overflow — Erratum 20 (printed p.75).** Specific large positive
   operands convert to 0 instead of overflowing (no IE). *Self-check:* documented
   operand → documented wrong FIST result, behind the flag. NOTE: Erratum 21
   ("Six Operands Result in Unexpected FIST Operation", printed p.77 — the small
   ±0.0625/±0.125/±0.1875 up/down case) is a **distinct** erratum and is NOT
   modelled; only Erratum 20 is reproduced.

3. **F00F — LOCK CMPXCHG8B with register destination — Erratum 81 (242480-041
   printed p.51).** The invalid `F0 0F C7 /reg` form locks/hangs the processor on
   affected steppings. *Reproduce:* decode that exact form → enter a HANG state
   (stop retiring / raise a `cpu_hung` flag) instead of the clean #UD. *Self-
   check:* assert the core hangs on that sequence and does NOT hang on valid
   CMPXCHG8B (memory) forms.

4. **MOV moffs (A2/A3) fails to pair — Erratum 59 (242480-022 printed p.99).** A
   *pairing* erratum → verifiable via the **cycle** gate. *Self-check:* an
   `A2/A3` MOV adjacent to a pairable op shows **no** U/V pairing in the RTL cycle
   trace (documented behavior), behind the flag.

## Deferred — NOT verifiable here (no oracle / need M2S system mode)

Documented but un-reproducible without system-mode/bus/real-silicon infrastructure
(track under M2S, not M6): all BTB-flush/SMM/NMI/STPCLK#/RSM (Errata 80, 2, 39,
49…), APIC and dual-processing (xAP/xDP) errata, CMPXCHG8B-page-boundary #UD
(Err 26) and EIP-corruption (Err 32) and 0F-misdecode (Err 42) which need the
exception/segment/cache-line-alignment paths M2S builds, FBSTP A/D-bit on 16-bit
wrap (Err 83, needs paging A/D), debug-exception-on-POPF/IRET (Err 79, needs
debug+exceptions), and the timing/perf-counter errata. List each in PROGRESS as
deferred with its reason.

## Gate (`make m6`)

- **Default (errata off): `make verify` stays fully GREEN** (M0–M5 unchanged) —
  HARD requirement; reproducing an erratum must never regress the clean core.
- **Errata on: the M6 self-check suite passes** — each reproduced erratum's test
  asserts the documented buggy behavior occurs (and that the corresponding clean
  behavior occurs with errata off). Verified against the spec-update documented
  cases, NOT QEMU.
- Honest reporting: which errata are reproduced + self-checked, which are deferred
  to M2S (with reasons), and that M6 is verified against documentation, not a
  differential oracle. If an erratum can't be made deterministically self-checkable,
  do NOT claim it — defer it.
