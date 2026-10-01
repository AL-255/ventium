# POP destination write-watchpoint provenance

Four tiny, unpaged CPL0 programs isolate the destination linear address used
for a POP memory write breakpoint. Every destination uses EBX or EBP, never
ESP, so the tests do not depend on the separate POP[ESP] post-increment fix.

Cases 1/2 require one DWORD/WORD DR0 write trap at the actual nonzero-FS/DS
destination. Case 3 is an ordinary SS-default EBP control. Case 4 arms DR0 at
the old SS-relative alias instead and requires no trap. Positive handlers check
the completed data, post-POP ESP, exact next IP, CS, saved flags and DR6.B0,
disable the watchpoint and IRET. All use SS.B=1, TF=0, no paging and a DWORD
trap gate. No fault records are filtered and no comparison masks are added.
The existing trace producer emits two adjacent records at the handler's first
PC: a delivery marker with the original ECX=0, then the first MOV with
ECX=post-POP-frame ESP. The checker requires both exact states, and the full
differential retains both records without filtering.

Host assembly only (fresh absolute artifact leaf):

```sh
make -C verif/sys/tests/ppopwatch OUTDIR=/absolute/fresh/fixtures
```

The standalone gate requires reviewed hashes and an existing prebuilt TB;
it never assembles images or rebuilds the model implicitly:

```sh
bash verif/sys/run-ppopwatch-gate.sh \
  --tb /absolute/frozen/tb_ventium --tb-sha256 SHA \
  --compile-sha256 SHA --fixtures /absolute/fresh/fixtures \
  --out /absolute/fresh/results --cases 1 --jobs 1
```

Each case has free pinned-QEMU exit133, a complete pinned-QEMU architectural
trace, native exit133 and normal footer, exact trap witnesses and an unfiltered
standard functional differential. The entire gate has a540-second cap;
per-child caps are30/90/60/30 seconds. No OS acceptance or performance gain
is inferred from these programs.
