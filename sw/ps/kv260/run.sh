#!/bin/sh
# run.sh — boot DOS Quake on the Ventium core. Lives in ~/ventium on the board
# (deployed by sw/ps/kv260/deploy.sh). ven_soc_app auto-spawns kms-draw for the
# live display; --vga-dump leaves a headless snapshot at /tmp/qframe.ppm.
#
# The board sudo password is read from stdin (piped per-invocation by
# `deploy.sh --run`, or `echo "$PW" | sh run.sh`) and used transiently to prime
# sudo's credential cache for this session — it is never written to disk.
cd "$(dirname "$0")"
IFS= read -r PW
echo "$PW" | sudo -S -v 2>/dev/null      # cache sudo creds for this session
PW=                                       # drop the secret from the environment
sudo pkill -f kms-draw 2>/dev/null; sudo pkill -f ven_soc_app_q 2>/dev/null; sleep 1
sudo sh -c 'nohup ./ven_soc_app_q --sys --dos --bios seabios.bin --disk quake_ven.img \
  --extmem-kb 64512 --vga-dump /tmp/qframe.ppm >/tmp/vsa.log 2>&1 & echo $! >/tmp/vsa.pid'
echo "ven_soc_app pid=$(cat /tmp/vsa.pid)"
# PS-PROGRAMMABLE retire comparator (no respin to retarget). Arm via devmem:
#   0xCC W = cmp_cfg {eip_care<<18, cs_care<<17, en<<16, match_cs[15:0]}
#   0xD0 W = cmp_range {eip_hi<<16, eip_lo[15:0]}
# Then READ: 0xCC=last-match eip, 0xD0=prev-match eip, 0xD4={seq[15:0],cs[15:0]}.
# CMP_TERMS default: match cs=0x0070 (the cs=0x70 drift), any eip. Override via $CMP_*.
CMP_CFG=${CMP_CFG:-0x00030070}   # en|cs_care|cs=0x0070  (set CMP_CFG/CMP_RANGE env to retarget)
CMP_RANGE=${CMP_RANGE:-0x00000000}
sudo busybox devmem 0xA00000CC 32 "$CMP_CFG"
sudo busybox devmem 0xA00000D0 32 "$CMP_RANGE"
echo "comparator armed: cfg=$CMP_CFG range=$CMP_RANGE"
# Poll the comparator AND watchdog the guest console: the instant the guest faults
# (Divide error / SIGFPE / abort), capture the fault-time state and KILL the run.
# Running on past a fault is pointless and can corrupt memory -> PS lock-up.
PREV=""
for i in $(seq 1 4000); do
  EV=$(sudo busybox devmem 0xA00000CC)
  if [ "$EV" != "$PREV" ]; then
    PREV=$EV
    echo "CMP last=$EV prev=$(sudo busybox devmem 0xA00000D0) info=$(sudo busybox devmem 0xA00000D4)"
  fi
  # guest-fault watchdog (GUESTCON lines are the guest teletype mirrored by ven_soc_app)
  if grep -aiqE 'division by zero|divide error|sigfpe|exiting due to signal|exception 0?6|unknown command given' /tmp/vsa.log 2>/dev/null; then
    echo "!!! GUEST FAULT DETECTED -> killing run immediately (no runaway)"
    echo "FAULT line: $(grep -aiE 'division by zero|divide error|sigfpe|exiting due to|exception|unknown command' /tmp/vsa.log | tail -1)"
    echo "=== fault-time cmp: last=$(sudo busybox devmem 0xA00000CC) prev=$(sudo busybox devmem 0xA00000D0) info=$(sudo busybox devmem 0xA00000D4) fsm=$(sudo busybox devmem 0xA0000094) eip=$(sudo busybox devmem 0xA0000084) cs=$(sudo busybox devmem 0xA0000088) ==="
    break
  fi
  if [ $((i % 250)) -eq 0 ]; then
    echo "t~$((i/40))s fsm=$(sudo busybox devmem 0xA0000094) eip=$(sudo busybox devmem 0xA0000084) cs=$(sudo busybox devmem 0xA0000088) cmp_last=$(sudo busybox devmem 0xA00000CC)"
  fi
done
echo "=== FINAL cmp: last(0xCC)=$(sudo busybox devmem 0xA00000CC) prev(0xD0)=$(sudo busybox devmem 0xA00000D0) info(0xD4)=$(sudo busybox devmem 0xA00000D4) (cfg=$CMP_CFG) ==="
sudo kill "$(cat /tmp/vsa.pid)" 2>/dev/null; sleep 1; sudo pkill -f kms-draw 2>/dev/null; sudo pkill -f ven_soc_app_q 2>/dev/null
echo "=== ven_soc_app log tail ==="; tail -15 /tmp/vsa.log
