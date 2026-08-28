# Win95 non-fast diagnostic run

This is the first timing-valid non-fast Win95 run from 2026-08-21. It began
from pristine disk SHA-256
`877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8`
and ran at a measured 2.9297 MHz.

The guest advanced from 121 to 1,247 disk reads, entered a blank B8000
graphics-mode proxy, and continuously retired in the `CS=05c1,EIP=1e5/1e6`
System-VM-style loop. It never met the source-controlled VMM/last-AR desktop
signature.

A diagnostic BIOS-buffer Enter was injected once. It was not consumed after
41 seconds. The logical BDA tail and shared comparator/flush phase were then
restored exactly. Because that flush changed the last-AR observation, this run
is diagnostic only and was stopped before the disk was restored for clean run
`ven-win95-clean2`.

One valid ten-second read-only counter interval before shutdown was:

```text
cycles=29297393 retired=571645 clock=2.929714MHz ipc=0.019512
io_cycles=0 irq_ack=133
axi rd_beats=0 ar_hs=0 b_hs=3059
raw cycles=6303539725->6332837118 retired=112166122->112737767
```

Do not use the old `fsm_pipe`/`fsm_pf` labels from that command output. The
external debug block hard-codes states 24/23, while the deployed feature set
places `S_PIPE/S_PF` at 27/26. The current probe reports semantic-free offset
names instead.
