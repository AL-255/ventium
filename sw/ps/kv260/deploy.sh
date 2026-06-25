#!/usr/bin/env bash
# sw/ps/kv260/deploy.sh — the canonical way to interact with the KV260 board.
#
# The host repo is the single source of truth. This cross-compiles EVERY board
# artifact locally (ven_soc_app + kms-draw) and mirrors them to ~/ventium/ on the
# board with `rsync --delete`, leaving NO source code or partial work on the board.
# After a power cycle, re-run this to fully restore the board's Ventium state.
#
#   sw/ps/kv260/deploy.sh                       # build + mirror artifacts (no sudo)
#   KV260_PW=... sw/ps/kv260/deploy.sh --run    # mirror, then run the DOS-Quake test
#   KV260_PW=... sw/ps/kv260/deploy.sh --bitstream   # also push + load ventium.bit.bin
#   BOARD=ubuntu@10.0.0.4 ...
#
# Credentials: the board sudo password is NEVER stored on the board or in git. The
# default mirror needs no sudo. --run / --bitstream require KV260_PW in the env and
# pipe it transiently per-invocation (matching the per-command convention).
#
# Large assets (seabios.bin, quake_ven.img, ventium.bit.bin) live in ./assets/ and
# the libdrm cross sysroot in ./sysroot/ — both gitignored, both the local source of
# truth (`make -C sw/ps/kv260 sysroot` re-fetches the sysroot from the board).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
BOARD="${BOARD:-ubuntu@10.0.0.4}"
SR="$HERE/sysroot"
DEST="ventium"                       # board dir: ~/ventium

DO_BIT=0; DO_RUN=0
for a in "$@"; do case "$a" in
  --bitstream) DO_BIT=1 ;;
  --run)       DO_RUN=1 ;;
  *) echo "unknown arg: $a"; exit 2 ;;
esac; done

if [ "$DO_BIT" = 1 ] || [ "$DO_RUN" = 1 ]; then
  : "${KV260_PW:?set KV260_PW in the env for --run/--bitstream (board sudo; passed transiently, never stored)}"
fi

# SERIALIZE all board operations. Running a --bitstream reload (xmutil unloadapp/
# loadapp) CONCURRENTLY with a live --run (which holds the PL→PS AXI master) makes the
# overlay removal STRAND an in-flight AXI burst, which HANGS the PS host hard (ssh =
# "No route to host"; recovery = physical power-cycle). One host-side deploy.sh may
# touch the board at a time — a second invocation waits, then refuses rather than
# overlapping. The lock auto-releases when this process exits (fd 9 closes).
LOCK="${TMPDIR:-/tmp}/ven_deploy_$(printf '%s' "$BOARD" | tr -c 'A-Za-z0-9' '_').lock"
exec 9>"$LOCK" || { echo "ERROR: cannot open board lock $LOCK"; exit 3; }
if ! flock -n 9; then
  echo "another deploy.sh is already touching $BOARD — waiting up to 600s (will NOT overlap board ops)..."
  flock -w 600 9 || { echo "ERROR: timed out on the board lock; refusing to run concurrently (would risk an AXI-strand PS hang)"; exit 3; }
fi

mkdir -p "$HERE/build"

echo "==> [1/6] cross-compile ven_soc_app (aarch64, static)"
make -s -C "$REPO/sw/ps/ven_soc_app" CROSS_COMPILE=aarch64-linux-gnu- STATIC=1 ven_soc_app

echo "==> [2/6] cross-compile kms-draw (aarch64, libdrm sysroot)"
aarch64-linux-gnu-gcc -O2 -Wall -I"$SR/include" -I"$SR/include/libdrm" \
  -o "$HERE/build/kms-draw" "$REPO/sw/ps/kms-draw/kms-draw.c" \
  -L"$SR/lib" -Wl,-rpath-link,"$SR/lib" -ldrm

echo "==> [3/6] stage board file set"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
install -m755 "$REPO/sw/ps/ven_soc_app/ven_soc_app" "$STAGE/ven_soc_app_q"
install -m755 "$HERE/build/kms-draw"                "$STAGE/kms-draw"
install -m755 "$HERE/run.sh"                        "$STAGE/run.sh"
install -m644 "$HERE/assets/seabios.bin"            "$STAGE/seabios.bin"
install -m644 "$HERE/assets/quake_ven.img"          "$STAGE/quake_ven.img"

echo "==> [4/6] mirror to $BOARD:~/$DEST (rsync --delete)"
ssh "$BOARD" "mkdir -p ~/$DEST"
rsync -a --delete --no-perms --omit-dir-times "$STAGE"/ "$BOARD:~/$DEST/"

echo "==> [5/6] strip any orphan source / partial work from board ~"
ssh "$BOARD" 'cd ~ && rm -f kms-draw.c kms-draw ven_soc_app_q ven_soc_app_q.bak \
  ven_soc_app_q.new f4a_board.sh f4a_board.sh.bak kt.sh diag.sh rd.sh rd2.sh \
  seabios.bin quake_ven.img .pw 2>/dev/null; true'

echo "==> [6/6] firmware / run"
if [ "$DO_BIT" = 1 ]; then
  BIT="${KV260_BITSTREAM:-$HERE/assets/ventium.bit.bin}"
  [ -f "$BIT" ] || { echo "bitstream not found: $BIT (set KV260_BITSTREAM)"; exit 1; }
  echo "    bitstream: push + load $(basename "$BIT")"
  scp "$BIT" "$BOARD:/tmp/ventium.bit.bin"
  # password piped to sudo -S over the ssh session; not stored on the board
  printf '%s\n' "$KV260_PW" | ssh "$BOARD" \
    "sudo -S sh -c 'cp /tmp/ventium.bit.bin /lib/firmware/xilinx/ventium/ventium.bit.bin && (xmutil unloadapp >/dev/null 2>&1 || true) && xmutil loadapp ventium' && rm -f /tmp/ventium.bit.bin"
fi
if [ "$DO_RUN" = 1 ]; then
  echo "    run: DOS-Quake test"
  # password piped to run.sh's stdin over the ssh session; not stored on the board
  printf '%s\n' "$KV260_PW" | ssh "$BOARD" "cd ~/$DEST && sh run.sh"
fi

echo "==> board ~/$DEST mirrors the host repo. No source or credential left on board."
