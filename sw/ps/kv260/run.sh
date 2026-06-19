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
for i in $(seq 1 14); do
  sleep 4
  F=$(sudo busybox devmem 0xA0000094); E=$(sudo busybox devmem 0xA0000084); C=$(sudo busybox devmem 0xA0000088)
  echo "t=$((i*4))s fsm=$F eip=$E cs=$C"
done
sudo kill "$(cat /tmp/vsa.pid)" 2>/dev/null; sleep 2; sudo pkill -f kms-draw 2>/dev/null
echo "=== ven_soc_app log tail ==="; tail -15 /tmp/vsa.log
