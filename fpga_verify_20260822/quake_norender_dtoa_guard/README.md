# Quake no-render bounded-dtoa discriminator

This executable-only discriminator adds a 32-digit ceiling to the libc float
formatter's fractional-digit loop. It is intended to prevent the observed
ASCII-zero stack overwrite from an invalid x87 value, while leaving ordinary
`%4.2f` conversions unchanged. It is not an RTL repair and only counts as a
workaround if pinned QEMU still produces the genuine 969-frame record and the
FPGA produces its own result record.

## Exact change

The hash-locked parent is
`../quake_norender_heapcap_noconback/QUAKE_NORENDER_HEAPCAP_NOCONBACK.EXE`,
SHA-256 `8e3a93dff2131a71dab904f00ca3b96a9507d6f1c6021b14cd721943f3db156d`.
At runtime address `0x548d1` (file offset `0x540d1`), the libc float formatter
previously used an unconditional x87-state-controlled loop backedge:

```text
0f 85 77 ff ff ff        jne 0x5484e
```

It is replaced in place with:

```text
83 7d dc 20              cmp dword ptr [ebp-0x24], 32
7c 77                    jl 0x5484e
```

`[ebp-0x24]` is the formatter's emitted-digit count. Normal `%4.2f`
conversions take the same loop iterations as before; only a nonconvergent x87
input is cut off before it can overwrite the caller's buffer. The resulting
`QUAKE_NORENDER_DTOA_GUARD.EXE` SHA-256 is
`679cc14c72aef596626664f752266924792e5c36dacdc81d74e00626ae680033`.

The guarded executable was FAT round-tripped byte-for-byte into the fresh
test image `qk_td_norender_dtoa_guard.vhd`, SHA-256
`1908ff56241c84bb16656f116f949d2d0034801013286834a0a03f0c81d1b808`.

`make_result_log_patch.py` then composes the already reviewed final-result
logger: it disables startup `-condebug` and enables it only around Quake's
existing timedemo-result `Con_Printf`. Its source and both byte contexts are
hash-checked, so the full-system QEMU and FPGA tests have a genuine guest-side
completion witness rather than relying on process lifetime. The composed
`QUAKE_NORENDER_DTOA_GUARD_RESULT.EXE` SHA-256 is
`70b0aec458c521867da29eb5d789f77e198b05cbdf484a61f140b6296c4d5bfb`; its
fresh FAT image is `qk_td_norender_dtoa_guard_result.vhd`, SHA-256
`98c3f2130f52957dda2af5df62791635403bc136ee1946b499f47581d4778a3b`.

## Validation status

The exact-profile RTL directed regressions `tx_stack`, `mb_fxch`, and `tx_fenv`
all differentially passed against pinned QEMU before this experiment.

### 2026-08-24 FPGA result: fail

The composed image was rebuilt into a clean sparse deployment image,
`qk_td_norender_dtoa_guard_clean.vhd`, SHA-256
`1cbe6f7635578a66d18973946a3287439cee02e462a28e111b30002e75271028`.
Before deployment, the only stale raw `969 frames` string inherited in free
space from an earlier image was zeroed; the board-side precheck then confirmed
that no result existed.

On the current `IDENT=a0486501` FPGA image, the guarded workload completed its
full 900-second daemon budget.  It read 450 IDE operations, then spent the
remainder in a CPU-only FreeDOS/DPMI phase.  It emitted neither `TIMEDEMO` nor
`969 frames`, and the disk hash remained exactly the clean input hash.  The
separate post-run checker reported:

```text
elapsed=15s lastEIP=000014c3 last_ar_guest=00001b00
QUAKE TIMEDEMO NOT COMPLETE (timeout)
```

This is a clean negative result, not a partial pass: the dtoa guard cannot be
credited with reaching Quake on FPGA.  The independent pinned-QEMU run is still
in progress at the time of this update, so it must not yet be described as a
QEMU-validated workaround either.

The filtered daemon log and the one-shot checker result are archived under
`evidence/` with SHA-256 values `8c5a60885e1e5ac2a5723f2b8c7c7fb1cba6f7fa5b11d9f3459da5d1e5e02ee2`
and `35ea3e7b822f57b537e9a45f05fc3a424234a486eed59a56969f075b4565ce9f`,
respectively.

### 2026-08-24 CR0 cache-enable control: fail

The same clean guarded disk was then run under the pre-existing, hash-locked
`boot0.rom` workaround that clears reset `CR0.CD/NW` before jumping back into
the production BIOS.  This is the architecture-preserving guest-ROM control
for the known non-cacheable L1D path; it must not be confused with an RTL
repair.  The board BIOS hashes were `d70623fb77e7e0d1c3eeadf6d436cd1b6f69cb73ebace6c6b86ccef7267ed32e`
(`boot0`) and `fb0d673a4cc3a96c388b4404db262db70bdde0746ee1ef9284923a5661e08296`
(`boot1`).

The full 900-second run again stopped with 450 reads and left the disk at
`1cbe6f7635578a66d18973946a3287439cee02e462a28e111b30002e75271028`.
Its postcheck reported `QUAKE TIMEDEMO NOT COMPLETE (timeout)` (last EIP
`000048af`).  Thus clearing CD/NW is not sufficient to make this guarded
workload reach Quake; it is a second clean negative control, not an acceptance
pass.  The archived filtered log and postcheck have SHA-256
`ac65010485ad3ed8623c4aedd76be83e52c4ee319cf23be67b28399bcec4cb48` and
`49f03f0e6457bb8145345bb6988943590f4ff3065c083d882b5bdc16d5cb8edb`.
