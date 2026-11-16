# FPGA Quake timedemo — `c0e3fe43` (2026-11-14) & `2886d24c` (2026-10-17)

## Latest Physical Release Result — Image `c0e3fe43` (2026-11-14)

**PASS: `969` frames in `121.2 s`, `8.0 FPS`** on the physical **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, Vivado 2025.2) at measured **`39.999802 MHz`** (`40.264133 MHz` post-route STA sign-off, `WNS +0.164 ns`, `WHS +0.010 ns`), running cold FreeDOS + DOS Quake `timedemo demo1` (`320×200`, sound off) in mandatory **`U/V + system fast-pipe`** mode (`cycle_mode=1`, `161` defines).

- **Current Verified Gameplay IPC (`c0e3fe43`):** **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only IPC) across interior gameplay cycles **`28,696,827,616–32,989,404,795`** (`2,214,014,744` total U+V events, `506,223,958` paired V retirements; `+3.88%` over the `2886d24c` `0.496499864` / `0.383002768` baseline). Counters include `REP`-element retirement.
- ** Artifacts & Full-Suite Qualification:** Raw bitstream SHA-256 `c0e3fe43b2b7ce88e013df107be94d56c0fcfcae626ce4c262975fba92dcc3b7`; `3,075`-frame raw `320×200` VGA capture (`15 fps` playback, palette compression only): [`quake-timedemo-c0e3fe43.gif`](quake-timedemo-c0e3fe43.gif). Unlike `2886d24c`, image `c0e3fe43` also closes 40 MHz slow-corner STA and passes the entire physical standard acceptance suite (both CoreMark seeds + cold Windows 95 GUI + interactive Quake gameplay; empirical single-board DRP runs also completed `demo1` at `58.824 MHz` and `11.6 FPS` wall-clock at `62.500 MHz`). See [`PUBLIC_FPGA_RELEASE_2026-11-14.md`](PUBLIC_FPGA_RELEASE_2026-11-14.md).

---

## Prior Baseline Run — Image `2886d24c` (2026-10-17)

**PASS: 969 frames in 125.8 seconds, 7.7 FPS**, on the physical
RK-XCZU15EG-F at measured **39.999826 MHz**, with **U/V + fast-pipe** enabled.
This is a cold FreeDOS boot running DOS Quake's original `demo1`, not a
simulation, snapshot restore, startup-only measurement or overclock projection.

Prior baseline gameplay IPC: **0.496499864 total U+V**, image **`2886d24c`**,
cycles **625,021,130,428–629,480,208,865**. Primary/U alone is **0.383002768**.
These counters include the existing REP-element retirement events; they are not
a separately deduplicated macroinstruction count.

## Movie

[Full recording, MP4 (18.3 MB)](/home/yukidama/external/tmp/ventium-quake-pll40-oct17.SJTmlsl0/movie/recording-15fps.mp4)

- 2,814 captured frames, **320×200**, **15 fps playback**, 187.6 seconds.
- Original captured colors; no gamma, brightness, contrast, resizing,
  interpolation, frame dropping or duplication. Lossless `libx264rgb` encoding
  is decoded back and all RGB bytes match the RGB332 capture expansion.
- Playback cadence is distinct from Quake's measured **7.7 rendered FPS**.
  This is sampled VGA output, not a one-record-per-engine-frame export.
- Capture sequences **240–3053** are consecutive; maximum capture gap
  **0.093682424 s**. Capture starts before observed demo frame0 and extends
  beyond frame 968, the demo-to-inactive transition and the result screen.
- The guest command is
  `quake -nosound -nocdaudio -condebug +timedemo demo1`; the movie is silent.

[Result screen](/home/yukidama/external/tmp/ventium-quake-pll40-oct17.SJTmlsl0/preview-1900.png)
and [closed guest console log](/home/yukidama/external/tmp/ventium-quake-pll40-oct17.SJTmlsl0/QCONSOLE.LOG).

## Completion and execution evidence

The private FAT16 disk retains the original result-free console prefix and
appends exactly one fresh demo1 invocation and one result:

```text
969 frames 125.8 seconds   7.7 fps
```

Independent engine/cycle samples bound the timed section to approximately
**123.866–127.997 seconds**, consistent with the guest's 125.8 seconds.
No terminal guest/daemon error, forensic freeze, running-mode guard failure,
watchdog timeout or forced daemon stop was observed.

The daemon exits **naturally with status 0** and closes its disk before grading.
The recorder receives a complete-record `SIGUSR1` stop after the recorded result
screen; its native exit is 0 and the host FIFO reader exits 0 with no partial
record. The watcher exits 0. Service invocation IDs and native PIDs are checked
through closure. All 76 retrieved evidence files match their board-side hashes.

The existing image was **not rebuilt or reprogrammed**. Normal RUN was used:
no STEP, breakpoint, snapshot, guest payload patch, U-only mode or global
slow-pipeline fallback. The source has all 159 pinned hardware defines,
including `VEN_SYS_FASTPATH`, `VEN_SYS_FASTPATH_RELOC`,
`VEN_SYS_FASTLOAD_FLAT`, `VEN_SYS_FASTLOAD_BOUNDED`, `VEN_SYS_FASTSTORE_FLAT`
and `VEN_FE_PIPE`; the shim connects `.cycle_mode(1'b1)`.

Actual fast pairing is independently visible in the coherent post-halt ring:
`DEC EBP` at `00a7:1057a` pairs with `JNE 10572` at `1057b`. Adjacent primary
entries 40→39 go directly from 1057a to 10572 in this build's **S_PIPE=28**.
The captured paging/segment mapping and original executable bytes agree.
The first offline recognizer only considered CMP/TEST+Jcc and rejected this
different loop; its failed attempt is retained. Extending the recognizer to
register DEC/INC+Jcc required no new board execution or altered evidence.

IPC uses all **54** qualifying consecutive intervals within the predefined
frame 33–900 interior, actually sampled at frames 44–882:

- **2,213,929,775 total U+V events** over a clock sum bounded by
  **4,458,841,239–4,459,307,333**.
- IPC uncertainty bounds: **0.496473916–0.496525814**.
- Independently sampled primary/U events: **1,707,837,659**, demonstrating
  approximately 506 million additional V retirements, not U-only execution.
- Engine fields are double-read physical-RAM witnesses with checked mappings,
  not coherent per-cycle cache snapshots. Startup and post-demo intervals are
  excluded; no intervals are selected by their IPC value.

This supersedes the older **simulation** gameplay baseline of 0.490014174,
executable `b6b92dbf`, cycles 1,100,065,247–3,100,065,247. Different platform/window
measurements are not a controlled attribution of optimization gains.

## Image, procedure and retained evidence

Installed firmware: `ventium_programmable_clock_40_oct17_power_r5.bit.bin`.
Raw-image SHA256:
`2886d24c5f9c84219f54e23a4766cfb7106f2999d28e794a0fd00256fd60cc52`.
See [clock implementation and physical sweep](../fpga/PROGRAMMABLE_CLOCK.md).
All 200 frozen base source pins were rechecked; the declared clock integration
edits and subsequent clock-only r5 replacement retain their original receipts.
The dirty current CPU checkout was not synthesized into this image.

The frozen cold runtime package and every result are under:

```text
/home/yukidama/external/tmp/ventium-quake-pll40-oct17.SJTmlsl0/
  package/                   pinned board helpers and input manifest
  prepared.json              package changes and expected hashes
  board-closed/              native logs, closed VHD, RAM/state/ring, IPC samples
  board-closed.tar.gz        transferred closed evidence
  capture/                   raw.vcap.gz and successful transport receipt
  movie/                     recording-15fps.mp4 and exact-color round-trip receipt
  audit_closed.py            independent final checker
  acceptance.json            combined timedemo/movie/IPC qualification
  retrieval-verified.json    all 76 board-file hashes match
  processor-source-recheck.json
  QCONSOLE.LOG
```

The run adapts the old fixed-clock controller only for the new image pin,
exact stable retained-primary-counter admission, always-on PLL readiness and
reset/DDR-drain cleanup without a PS-clock write. It independently baselines
the resettable U+V counter. The original disk/BIOS/daemon are unchanged; only a
private sparse disk copy is writable. The historical daemon 600/watch 3600 budget
is retained; natural disk closure is mandatory. Do not reuse this sealed run
directory or blindly run the older controller's hardcoded image/clock settings.
Host checks passed: 39 cold-controller, four private PLL-cleanup, 12 Quake-IPC,
15 movie and 21 streaming tests. These are tool checks, not processor gates.

SHA256 receipts:

- Movie: `db6df4e0d7b74a69a3edaafa79b31aa0dbb82a9a97183b33fcd3a328efe0e292`
- Closed archive: `34e0896162fff25770f69ab9c2a7195912751aade80f641756974ebbb4b421a4`
- Acceptance: `73895bf81795480f29229d5bbb683ef8a125a8e96110fe572089aac58b5ec19f`

Final board state: guest held reset, actual posted DDR drained (`50440003`),
PLL divide25 locked/enabled/error-free; independently remeasured
**39.999829 MHz**. No guest, recorder or watcher process remains.

**Scope:** this qualifies one complete physical Quake timedemo at 40 MHz on this
image. It does not establish Win95 acceptance, the whole standard suite,
40 MHz STA sign-off, or Quake reliability at the higher CoreMark-tested clocks.
