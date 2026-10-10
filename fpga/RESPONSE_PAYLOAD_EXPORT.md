# Current-response payload hardware backport — October 10

**UNQUALIFIED; not deployed.** This is the FPGA export of full-PC model
`c883878de2e262f4845fc05d68b7ccf81db7c423c8d8c49f72892eccd50f0ed7`.
It retains UV/system/relocated fast paths, full P5 L1s, 256 KiB platform L2,
posted-16 transport and the unchanged **40 MHz core / 100 MHz PL** constraints.

The preceding unplaced path was 165 levels, from EIP through successor
lookahead/tag qualification and current read data to paired-memory acceptance.
The [response selector](../verif/l1/RESPONSE_PAYLOAD.md) removes the younger
lookahead dependency from the current saved-data mux without changing ACK,
permissions, RAM ports, latency or pipeline registers. The numeric SRT-floor
repair is included; **C1 defects remain**. The newer C1 work is separate and
does not alter this frozen export.

## Source closure and checks

Export: `external/tmp/ventium-response-payload-fpga40.bic0fW5S`.
Manifest: `3ab7194b6004cea114ad709014d7d171587bfe8bc303fbc58469d3d8801fa5de`.
The [freezer](freeze_response_payload_rk_candidate.py) admits only the exact
native model and the preceding `9e7b6b78` hardware manifest. There are 190
payload files, 154 hardware defines, 117 filelist units and 49 include edges.
All 170 non-wrapper compiled source payloads match the native compilation;
the unchanged hardware top's simulation projection is checked independently.
Only these parent RTL files change:

- `rtl/mem/ven_l1d.sv`: SHA256 `f812ea7b5147638c03afe544f7ce76384272007069b3fa022cb9e7032bce6583`.
- `rtl/fpu/fpu_srt_div.sv`: SHA256 `8423aef07272fd2b1d49f1a68db2a0aad67afe26de0fa385343f8bd714ab9d52`.

Six host freezer tests and **53 real Tcl profile checks pass**, including
missing/reordered/duplicated feature negatives. The freezer initially refused
an `external`-symlink argument before writing payloads; canonical paths passed
the unchanged no-unreviewed-symlink checks.

Strict hardware **CPU-hierarchy** lint passes native 0 in 2.49 seconds,
154 defines and unchanged input hashes, with all six structural classes fatal.
Root `ventium-response-payload-hw-lint.I3yTPKTS`; supervisor invocation
`f4b10b29cc5246269344c3e5c56ddf72`. This is not full-platform lint or FPGA acceptance.

The source model already passes 2,560 directed full QEMU comparisons, 1,280
identical complete cycle-record pairs, saved-window/critical-word ownership
tests, and both short CoreMark diagnostics at unchanged parent ticks/CRCs.
The canonical gate remains **FAIL**; no masks, golden results or bands were
waived. The short CoreMark diagnostics are duration-invalid, not qualified scores.

## Bounded physical measurement, running

Synthesis starts **16:46:18 UTC** in
`ventium-response-payload-full-synth-r2.3S8UDweV`, controller invocation
`9c48d0458fa84ad0a831679bcc9a0153`; sole Vivado-family scope invocation
`816fa34f893d44b5b087de92690c0ce7`. The same `logic_only` mapper is used for
comparison: 8 GiB RAM, 6 GiB swap, one job, 30-minute native bound, unchanged
12 GiB initial disk reserve and live host/disk guards. The controller cannot
place, route or program the board. Read its native closure and independent
DCP/clock audit before quoting new utilization or frequency.

The first controller (`ventium-response-payload-full-synth.EusyJxCV`) failed
before starting Vivado: it expected a generic `passed` key in the numeric-only
SRT audit. R2 explicitly requires its 912-case numeric pass **and retains the
456 C1 failures/whole-observer failure**. No RTL, measurement, guard or acceptance
criterion was changed to conceal that debt.

Preflight recovered **1,328,333,722 bytes** by archiving closed generated
compiler `.o/.a/.gch` files. Every archive was compared with the originals and
hashed before unlinking; original sources, host objects, binaries, traces and
reports remain. Each affected run has a `generated-object-archive-closed.json`
receipt and a recovery command. The failed r2 fixture's known later repository
edit is recorded as external pin drift, not relabelled a passing run.

## Performance and acceptance boundary

Latest verified gameplay remains **0.49940993 U+V retirement-event IPC** on
`bfb867f7`, cycles **3,200,065,237–3,300,065,237**. All 21 consecutive windows
from 1,200,065,237 average **0.4895819671**. That same older model qualifies
at **2.101890118 / 2.107616105 CM/MHz**. These measurements are not inherited
by `c883878d`, which is gameplay-unmeasured and has no own duration-valid score.
Complete timedemo, green differential gates, full standard suite and FPGA
deployment remain open. REP retirement events are not P54 macroinstructions.
