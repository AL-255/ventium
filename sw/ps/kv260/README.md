# KV260 board deployment

`deploy.sh` is the **canonical way to interact with the KV260 board**. The host
repo is the single source of truth: the script cross-compiles every board artifact
locally and mirrors them to `~/ventium/` on the board with `rsync --delete`,
leaving **no source code or partial work** on the board. After a power cycle, one
`deploy.sh` fully restores the board's Ventium state.

## Usage

```sh
sw/ps/kv260/deploy.sh              # build (ven_soc_app + kms-draw) + mirror artifacts
sw/ps/kv260/deploy.sh --run        # ... then run the DOS-Quake test (run.sh on board)
sw/ps/kv260/deploy.sh --bitstream  # ... also push + load assets/ventium.bit.bin (firmware)
```

Overridable env: `BOARD` (default `ubuntu@10.0.0.4`), `KV260_PW`, `KV260_BITSTREAM`.

## What lands on the board (`~/ventium/`, mirrored — nothing else)

| file             | source                                   |
|------------------|------------------------------------------|
| `ven_soc_app_q`  | cross-built `sw/ps/ven_soc_app`          |
| `kms-draw`       | cross-built `sw/ps/kms-draw` (libdrm)    |
| `run.sh`         | `sw/ps/kv260/run.sh`                      |
| `seabios.bin`    | `assets/seabios.bin`                     |
| `quake_ven.img`  | `assets/quake_ven.img`                   |

The bitstream lands in `/lib/firmware/xilinx/ventium/` via `--bitstream`.

The board sudo password is **never stored** on the board or in git. The default
mirror needs no sudo; `--run`/`--bitstream` require `KV260_PW` in the host env and
pipe it transiently over the ssh session (matching the per-command convention).

## Local build deps (gitignored, re-fetchable from the board)

- `sysroot/` — aarch64 libdrm headers + lib for cross-building kms-draw.
- `assets/` — `seabios.bin`, `quake_ven.img`, `ventium.bit.bin` (large; local source of truth).

Re-fetch either from the board with `make -C sw/ps/kv260 sysroot` if lost.
