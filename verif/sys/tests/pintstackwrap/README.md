# Same-privilege INT3 stack-address-size witness

This standalone, unregistered directed gate separates the reproduced
same-privilege DWORD interrupt-frame address bug from the far-transfer width
bug. A 32-bit gate still uses SP, not full ESP, when SS.B=0. For these INT3
cases the global implicit stack writeback merge already preserves ESP's upper
half; the repaired defect is the unmasked S_INT_PUSH memory address.

Eight images cover WORD/DWORD interrupt gates × SS.B0/B1 × low/high placement.
B0 has ESP high `DEAD`, with SP1000 or SP0000 (the latter wraps to FFFx). B1 has
ESP1000 or ESP10000 and does not wrap. All code is CS.D=1, baseF0000, so WORD IP
slots remain genuine 16-bit segment offsets. Handlers read actual IP/CS/FLAGS,
exact handler ESP, and adjacent guard sentinels through flat DS before any stack
instruction. They then IRET in the gate's width, and the caller checks full
restored ESP and exactly one handler entry.

Case1/5 are the DWORD/B0 discriminators; case2/6 WORD/B0 and all B1 cases are
controls. No error-code or privilege-switch frame is claimed covered. The
existing pint16f fixture is complementary. Intel's protected INT push algorithm
and pinned QEMU do_interrupt_protected choose slot width from gate type and
stack-address mask from SS.B independently.

Host assembly only, into an explicit fresh root-filesystem leaf:

```sh
make -C verif/sys/tests/pintstackwrap OUTDIR=/absolute/owned/obj_dir_new check-host -j2
```

After parent review, a separately authorized prebuilt frozen-model gate:

```sh
bash verif/sys/run-pintstackwrap-gate.sh \
  --tb /absolute/obj_dir_X/tb_ventium --tb-sha256 SHA \
  --compile-sha256 SHA --fixtures /absolute/owned/obj_dir_new \
  --out /absolute/owned/obj_dir_fresh_gate --cases all --jobs 2
```

The wrapper uses the normal serialized4GiB/64-task guard and a540-second hard
deadline; it never builds a model or guest implicitly. Every selected case
requires free QEMU exit133, a complete QEMU trace and exit footer, actual native
exit133 with a unique genuine debug-exit/retirement/I/O footer, zero canonical
fault events, exact terminal witnesses, all-record/all-state differential, and
unchanged frozen inputs. Stdout and stderr stay separate until closed. Quiescent
exit0, wrong gates/frames, missing input pins, and truncated traces fail closed.

Host synthetic negative tests are not execution evidence. No DUT run or passing
result is claimed merely by creating or syntax-building these files. No Windows95
causality is implied by this independent stack-frame defect.

October1 execution: pre-fix model `ba8effe8` produced #SS in cases1/5, with
quiescent exit0; all six controls passed. The address-only `stk16` repair on
model `4f5e65cf` passes all eight full pinned-QEMU differentials, each with
actual exit133, zero faults, 83 records and 824 clocks. The 32-case far-width
regression and fast functional/timing gates also pass on that model. No new
pipeline state, guest patch or stall is added. This remains directed evidence,
not Windows95 desktop or standard-suite acceptance. A separate stale explicit
ESP decode-metadata trap hypothesis is not covered by INT3.
