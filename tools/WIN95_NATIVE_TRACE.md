# Bounded Windows 95 VTM Replay Helper (`tools/run_win95_native_trace.py`)

`tools/run_win95_native_trace.py` stages and validates a bounded VTM
retirement-log replay from a hash-pinned 200M-cycle simulator checkpoint bundle
(`--snapshot-v3`).

> **Historical Diagnostic Context (`c0e3fe43`, 2026-11-14):** This helper
> replays a specific September 2026 wave-9 simulator bundle for historical VxD
> trace inspection; it is **not** a Windows 95 acceptance gate, QEMU
> differential, or `.vtrace` generator. Cold **Windows 95 OSR2** boot to GUI
> desktop with multi-application PS/2 mouse/keyboard interaction and clean OS
> shutdown is physically qualified on **RK-XCZU15EG-F** release image
> **`c0e3fe43`** (`40.264133 MHz` STA-signed-off, `161` defines,
> `cycle_mode = 1'b1`), alongside verified physical DOS Quake gameplay IPC of
> **`0.515778001` total U+V** (`0.397847833` primary/U-only) across cycles
> **`28,696,827,616–32,989,404,795`**.

---

## Usage & Scratch Rules

Output and `TMPDIR` must point to a fresh, non-symlink directory on real
writable scratch storage (`/home/yukidama/external/tmp`, never inside a source
archive or repository symlink).

Inspect the staged execution plan without creating directories or starting a
simulator:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B tools/run_win95_native_trace.py \
  --bundle /path/to/pinned/wave9-win95-bundle \
  --out /home/yukidama/external/tmp/win95-native-trace-plan
```

Launch an explicitly authorized bounded replay inside the repository build
scope:

```sh
TMPDIR=/home/yukidama/external/tmp tools/build_scope.sh -- \
  python3 -B tools/run_win95_native_trace.py \
  --bundle /path/to/pinned/wave9-win95-bundle \
  --out /home/yukidama/external/tmp/win95-native-trace-run --run
```

---

## Validation Contract & Endpoint Caveat

- **Immutable Bundle Staging:** Verifies all five SHA-256 pins via
  `tools/checkpoint_bundle.py` (frozen simulator binary, BIOS/VGA ROMs,
  200M-cycle v3 snapshot at `31,255,534` retirements, and disk image), stages
  independent copies (writable private disk only, never hardlinks), strips
  inherited debug/preload overrides, and hashes all inputs/outputs into
  `receipt.json` even on failure.
- **VTM Window Checks:** Requests `--vtm-dump-start 40150000 --vtm-dump 400000`
  (ordinals `40,150,000–40,549,999` extracted verbatim into `retire.vtm.log`
  from `capture.log`, never hand-formatted as `.vtrace`) and checks monotonic
  cycle timestamps with `<= 2` retirements per cycle.
- **Outer-Loop Disk-Tick Overshoot Note:** In the pinned wave-9 binary, IDE
  sector servicing advances `ps_clock_tick` inside `x86_poll` before the outer
  loop rechecks `--save-at` / `--cycles` (for example stopping at `258,589,523`
  rather than `258,500,000`). The runner enforces its strict exact-stop contract
  honestly and records any overshoot as a `FAIL` receipt rather than waiving it.

## Host Unit Tests

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s tools -p test_win95_native_trace.py -v
```
