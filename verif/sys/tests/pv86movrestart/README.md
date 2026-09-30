# V86 byte-read restart fixture

Status: **all four cases pass pinned-QEMU architectural comparison in both
functional and cycle mode**, on the frozen TB below. Every case also passes
the independent timing-trace no-pair/order check, nine-byte state checks and
guest debug-exit 133. Cases 1–4 compare 1188/1773/1773/1804 records respectively.
Executed artifacts: `/tmp/ventium-pv86movrestart.JLymRE/`; the bounded driver
was reaped with exit zero. This directory is not yet registered in the umbrella
system suite. The usual bare-metal RWX ELF-segment linker warning remains visible.

The first execution (`/tmp/ventium-pv86movrestart.04Jmph/`) passed case 1's
functional comparison and cycle-mode guest self-check, then rejected the
timing-only trace as lacking system-state fields. This was a harness-format
error, not a DUT failure. The corrected runner separates the timing proof from
the `--cycle-func` architectural trace; no RTL or differential mask was changed.

This generic architectural regression checks `MOV AL, ES:[BX]`, `INC AH`,
`INC BX` and 16-bit `LOOP` around a precise user-read page fault and V86
interrupt-gate returns. It contains no BIOS, Windows, Quake, snapshot or
workload-specific behavior. It starts from reset.

All four cases read nine bytes beginning at `2000:0FFD`. ES page `20000` maps
to physical `50000`; next page `21000` initially has a not-present PTE with
physical backing `51000`. The first three bytes, including the byte at the
page end, must retire without touching the absent page. The fourth read must
fault exactly once with error 4 and CR2=`21000`.

At that fault the monitor checks source CS:EIP, VM/IOPL, all saved GPRs and
V86 segment selectors: EAX=`ABCD8142`, EBX=`13571000`, ECX=`24680006`,
EDI=`87650003`, ES=`2000`, DS=`3000`, SS=`4000`, SP=`F000`. AH and AL must
still contain their preceding committed values. The handler sets live ES/DS
to the flat protected-mode selector and performs 32-bit memory/register
operations, but does not rewrite the saved guest frame/GPRs. It repairs only
the absent PTE and returns with IRETD. The guest retries the **same ES:BX byte
instruction without reloading ES**, so a lost hidden ES base or stale 32-bit
decode/address context cannot be hidden by fixture setup.

The final register checks are EAX=`ABCD87FE`, EBX=`13571006`, ECX=`24680000`,
EDI=`87650009`; full high-half sentinels and unaffected registers must survive.
The monitor also checks the nine output bytes and exact fault/event counts.

| Case | Additional event placement | Event count |
| --- | --- | --- |
| 1 | None; page-fault retry alone | 0 |
| 2 | Software INT30 after each successful byte MOV | 9 |
| 3 | Software INT30 after the INC AH/BX/DI group | 9 |
| 4 | Software INT30 after each taken/final LOOP | 9 |

Cases 2–4 use a deterministic DPL3 software interrupt gate and an unmodified
V86 frame/IRETD. They check the exact saved source EIP and operands at each
placement, then deliberately change the handler's live segment/register
context. They are **not external/hardware-IRQ injection tests**. Guest IF is
clear. A hardware-IRQ witness needs a separately approved injection-capable
TB and golden producer; the current raw frozen TB has no such interface.

## Bounded invocation (do not run without authorization)

Use the existing bounded launcher and an outer deadline no longer than 600s:

```bash
TB_BIN=/tmp/obj_dir_cm_p54_iret_sep30/tb_ventium \
  tools/build_scope.sh -- timeout --kill-after=5s 590s \
  bash verif/sys/tests/pv86movrestart/run-pv86movrestart-gate.sh
```

That reference binary has SHA256
`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`.
Choose an available port via `QEMU_PORT` (default 41437) and optional `CASES`.
The runner requires an already-active capped/locked build_scope and an
explicit executable TB. It **never builds or replaces a model**, including
the canonical model. It only assembles the four small BIOS images after
execution is authorized, writes to a unique `/tmp` directory, and preserves
all hashes, argv, images, symbols, logs and canonical traces.

The gate deadline is 540s plus at most 5s termination grace, with smaller
per-command caps, 5000 instruction and 2M cycle caps. QEMU is the pinned
`qemu-system-i386 -cpu pentium` producer. A separate `--cycle` timing trace
must establish zero paired retirements and identical instruction order/count
before `--cycle-func` architectural comparison is allowed. Both RTL functional
and cycle-mode full-state runs compare with `compare.py --mode func --all`;
this does not claim cycle-exact timing. The checker imports `tracefmt.py`, verifies
the completion marker and all nine successful read states, and checks hidden
segment bases only when those optional canonical fields are present. The
assembly checks the actual saved fault frame rather than inferring it from
the legacy pre-NBA CR2 log. Default differential masks/tolerances are untouched.

The timing-trace qualifier also has 22 passing host-only tests, including
read-only rechecks of the retained four-case traces:

```bash
PV86MOVRESTART_ARTIFACT_DIR=/tmp/ventium-pv86movrestart.JLymRE \
  python3 -B verif/sys/tests/pv86movrestart/test_check_trace.py -v
```

The synthetic negative cases use canonical `tracefmt.py` builders/serializer;
no DUT, compiler or QEMU is launched by these tests.

No full-PC launch, standard-suite pass, VDD causality claim, or performance
claim follows from passing this focused fixture. Frozen
full-PC b7 lacks `VEN_DBG_WD`; its `VEN-PFW` walker diagnostic must not be
promised as a plusarg-only observer.
