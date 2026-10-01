# Explicit ESP destination followed by a wrapped #DB frame

Two standalone, unregistered images test TF after `MOV ESP,imm32` and
`LEA ESP,[EAX]`. Initial ESP=BEEF7000 changes explicitly to DEAD0000 while
SS.B=0; successful explicit writes must remain full32-bit. A DWORD #DB gate
then pushes at low offsets FFFC/FFF8/FFF4 and must leave handler ESP=DEADFFF4.

The reference q destination metadata survives the trap handoff. If
`esp_arch_dst` keeps treating that old destination as the owner of S_INT_PUSH,
the implicit WB bypasses its high-half merge and commits DEACFFF4. The earlier
S_INT_PUSH address-wrap correction is a prerequisite: without it the first
implicit store faults instead and does not isolate the WB corner.

POPF runs with TF=0, installs TF=1, and is immediately followed by the tested
MOV/LEA. The handler checks actual full ESP before any stack operation, reads
the real saved next IP/CS/FLAGS through flat DS, verifies DR6=FFFF4FF0 (BS only),
and checks adjacent guards. It clears saved TF before IRETD. The caller verifies
full restored DEAD0000 and exactly one handler entry. Thus a premature POPF
trap, a swallowed BEEF→DEAD explicit high-half write, wrong frame, missing trap,
or a subsequent hidden #DB cannot pass the self-check or full differential.

Host assembly uses an explicit fresh canonical leaf. Validation is unconditional,
including when an existing output has up-to-date image targets:

```sh
make -C verif/sys/tests/pespdebugwrap OUTDIR=/absolute/owned/obj_dir_new check-host -j2
```

After parent review, only a separately authorized frozen-model gate:

```sh
bash verif/sys/run-pespdebugwrap-gate.sh \
  --tb /absolute/obj_dir_X/tb_ventium --tb-sha256 SHA \
  --compile-sha256 SHA --fixtures /absolute/owned/obj_dir_new \
  --out /absolute/owned/obj_dir_fresh_gate --cases all --jobs 2
```

The gate reuses the reviewed closed pverrw contracts: pinned QEMU8.2.2, actual
compile-profile SEG_ENFORCE, source hashes, separate stdout/stderr until EOF,
normal serialized4GiB/64-task guard, hard540-second whole scope, individual
QEMU≤90s/native≤60s, real133 exits, complete unique footer/I/O evidence, no
ordinary fault events, exact trap transitions/witnesses, and complete standard
functional differential with no new masks or row filtering. The existing
defined/undefined EFLAGS masks still apply; the directed witness separately
checks live TF/RF, saved FLAGS/IP, full ESP and DR6. No build is implicit.
Host negatives are not execution evidence.

On October 1, the frozen `9a7976f7…` TB passes both cases against pinned QEMU:
96 records / 936 clocks each, actual exit133 and exactly one TF trap. The
preceding `4f5e65cf…` TB fails both with actual handler ESP=DEACFFF4 rather
than DEADFFF4. These are directed architectural results, not an OS boot or
standard-suite pass. See `docs/WIN95_BITSTRING_FIX_2026-09-30.md` for provenance.
