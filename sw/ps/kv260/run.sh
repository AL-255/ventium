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
# ===== SETUP-RULE-OUT EXPERIMENT (VENSLOW=1): clock the PL core to ~496 kHz (<1 MHz) =====
# PL0_REF_CTRL 0xFF5E00C0: DIVISOR0[13:8], DIVISOR1[21:16], IOPLL=1000MHz.
# 63*32 -> ~0.496 MHz = ~80x the 40MHz clock period of setup margin. If the #DE STILL
# fires this slow, setup timing is ruled out (the path has ~80x slack). Core is idle here
# (ven_soc_app killed), so changing the clock is safe (no in-flight AXI). Restore with div0=25.
if [ "${VENSLOW:-0}" = "1" ]; then
  CRLV=$(sudo busybox devmem 0xFF5E00C0)
  NEWV=$(printf '0x%08x' $(( (CRLV & 0xffc0c0ff) | 0x00203f00 )))   # DIV0=63 DIV1=32 -> ~496 kHz
  sudo busybox devmem 0xFF5E00C0 32 "$NEWV"
  echo "VENSLOW: PL0_REF_CTRL $CRLV -> $(sudo busybox devmem 0xFF5E00C0)  (~496 kHz, DIV0=63 DIV1=32)"
  sudo sh -c 'nohup env VEN_RTL_IRQ=1 VEN_FIXED_IRQ0_HALF=$(cat /tmp/ven_irq0_half 2>/dev/null) ./ven_soc_app_q --sys --dos --bios seabios.bin --disk quake_ven.img \
    --extmem-kb 64512 --vga-dump /tmp/qframe.ppm >/tmp/vsa.log 2>&1 & echo $! >/tmp/vsa.pid'
  echo "VENSLOW: ven_soc_app pid=$(cat /tmp/vsa.pid); watching for the #DE at <1MHz (up to ~40min)"
  RES="CLEAN"
  for i in $(seq 1 2400); do
    sleep 1
    if grep -aiqE 'division by zero|divide error|sigfpe|exiting due to|general protection|exception 0' /tmp/vsa.log 2>/dev/null; then
      RES="FAULT"
      echo "VENSLOW RESULT: #DE STILL FIRES at ~496 kHz => SETUP TIMING RULED OUT (~80x slack)"
      echo "FAULT line: $(grep -aiE 'division by zero|divide error|exception|exiting due to' /tmp/vsa.log | tail -1)"
      break
    fi
    if [ $((i % 60)) -eq 0 ]; then echo "VENSLOW t~${i}s eip=$(sudo busybox devmem 0xA0000084) cs=$(sudo busybox devmem 0xA0000088) loglines=$(wc -l </tmp/vsa.log 2>/dev/null)"; fi
  done
  [ "$RES" = "CLEAN" ] && echo "VENSLOW RESULT: NO #DE in ~40min at ~496 kHz => the bug did NOT occur slow (was setup-dependent) OR boot didn't reach Quake in time"
  echo "VENSLOW: restoring 40 MHz (DIV0=25 DIV1=1)"
  CRLV=$(sudo busybox devmem 0xFF5E00C0); NEWV=$(printf '0x%08x' $(( (CRLV & 0xffc0c0ff) | 0x00011900 )))
  sudo busybox devmem 0xFF5E00C0 32 "$NEWV"; echo "VENSLOW: clock now $(sudo busybox devmem 0xFF5E00C0)"
  sudo kill "$(cat /tmp/vsa.pid)" 2>/dev/null; sleep 1; sudo pkill -f kms-draw 2>/dev/null
  echo "VENSLOW DONE"; exit 0
fi
sudo sh -c 'nohup env VEN_RTL_IRQ=1 VEN_FIXED_IRQ0_HALF=$(cat /tmp/ven_irq0_half 2>/dev/null) ./ven_soc_app_q --sys --dos --bios seabios.bin --disk quake_ven.img \
  --extmem-kb 64512 --vga-dump /tmp/qframe.ppm >/tmp/vsa.log 2>&1 & echo $! >/tmp/vsa.pid'
echo "ven_soc_app pid=$(cat /tmp/vsa.pid)"
# ---- STRICT CLOCK-STEP validation: freeze the core clock, pulse 1 clk at a time,
# watch the FSM micro-state (0x94) advance per pulse. RUNCTL(0xDC)[4]=mode [5]=pulse.
if [ "${CLKSTEP:-0}" = "1" ]; then
  # FAULT-FREEZE: freeze the core clock on the Nth exception delivery (= the drift's
  # fault, past the handled boot faults) BEFORE the triple-fault rst_n wipes the ring.
  # cfg[22]=fault-freeze mode, cfg[31:24]=skip. Tune SKIP via env (no rebuild).
  # skip = which exception delivery to freeze on. Sweep it WITHOUT re-editing run.sh:
  # `ssh board 'echo N | sudo tee /tmp/ven_skip'` before each `deploy.sh --run`.
  SKIP=$(cat /tmp/ven_skip 2>/dev/null || echo "${SKIP:-1}")
  CMP_CFG=$(printf '0x%08x' $(( 0x00400000 | (SKIP<<24) )))
  sudo busybox devmem 0xA00000CC 32 "$CMP_CFG"
  sudo busybox devmem 0xA00000D0 32 0x00000000
  echo "clkstep: fault-freeze armed cfg=$CMP_CFG skip=$SKIP; waiting for the clock to freeze at fault #$SKIP..."
  PEIP=""; FRZ=0
  for i in $(seq 1 4000); do
    EIP=$(sudo busybox devmem 0xA0000084)
    if [ "$EIP" = "$PEIP" ]; then FRZ=$((FRZ+1)); else FRZ=0; PEIP=$EIP; fi
    if [ "$FRZ" -ge 150 ]; then echo "clkstep: CLOCK FROZEN (PC stopped)"; break; fi
  done
  echo "FROZEN: eip=$(sudo busybox devmem 0xA0000084) cs=$(sudo busybox devmem 0xA0000088) fsm=$(sudo busybox devmem 0xA0000094)"
  echo "CKDONE"; sudo kill "$(cat /tmp/vsa.pid)" 2>/dev/null; sleep 1; sudo pkill -f kms-draw 2>/dev/null
  exit 0
fi
# PS-PROGRAMMABLE retire comparator (no respin to retarget). Arm via devmem:
#   0xCC W = cmp_cfg {eip_care<<18, cs_care<<17, en<<16, match_cs[15:0]}
#   0xD0 W = cmp_range {eip_hi<<16, eip_lo[15:0]}
# Then READ: 0xCC=last-match eip, 0xD0=prev-match eip, 0xD4={seq[15:0],cs[15:0]}.
# CMP_TERMS default: match cs=0x0070 (the cs=0x70 drift), any eip. Override via $CMP_*.
# FREEZE-ON-Nth-MATCH: cfg[19]=freeze, cfg[31:24]=skip. Freeze the PC ring when the
# reset vector eip=0xfff0 is reached (the #DE triple-fault reset) so it survives -
# the frozen ring then holds the trajectory INTO the fault. skip=0 -> first 0xfff0
# the cmp sees. Adjust skip / target via CMP_CFG/CMP_RANGE to triangulate.
CMP_CFG=${CMP_CFG:-0x00110000}   # en + freeze-on-#DE (cfg[20]): freeze the PC ring when the divide #DE fires
CMP_RANGE=${CMP_RANGE:-0x00000000}
sudo busybox devmem 0xA00000CC 32 "$CMP_CFG"
sudo busybox devmem 0xA00000D0 32 "$CMP_RANGE"
echo "comparator armed: cfg=$CMP_CFG range=$CMP_RANGE"
# Poll the comparator AND watchdog the guest console: the instant the guest faults
# (Divide error / SIGFPE / abort), capture the fault-time state and KILL the run.
# Running on past a fault is pointless and can corrupt memory -> PS lock-up.
PREV=""
# RUNITERS bounds the run length (each iter ~25ms of devmem polling). Default is long
# enough for Quake's ~4-6 min on-silicon Alpha_Init + the timedemo to render; the
# early-exit on a real guest fault / core-halt below still stops it the instant it faults.
for i in $(seq 1 ${RUNITERS:-24000}); do
  EV=$(sudo busybox devmem 0xA00000CC)
  if [ "$EV" != "$PREV" ]; then
    PREV=$EV
    echo "CMP last=$EV prev=$(sudo busybox devmem 0xA00000D0) info=$(sudo busybox devmem 0xA00000D4)"
  fi
  # core-halt detect: the VEN_DBG_CORE build HALTs at a divide #DE (no banner), so the
  # committed PC stops advancing. A halted core can't run away -> safe to capture+stop.
  EIP=$(sudo busybox devmem 0xA0000084)
  if [ "$EIP" != "0x00000000" ] && [ "$EIP" = "$PEIP" ]; then HSTUCK=$((${HSTUCK:-0}+1)); else HSTUCK=0; PEIP=$EIP; fi
  if [ "${HSTUCK:-0}" -ge 120 ]; then
    echo "!!! CORE HALTED (PC frozen at eip=$EIP cs=$(sudo busybox devmem 0xA0000088) fsm=$(sudo busybox devmem 0xA0000094)) -> #DE halt-in-core; capturing frozen ring"
    break
  fi
  # guest-fault watchdog (GUESTCON lines are the guest teletype mirrored by ven_soc_app)
  if grep -aiqE 'GUESTFAULT|division by zero|divide error|sigfpe|exiting due to signal|exception 0?6|unknown command given' /tmp/vsa.log 2>/dev/null; then
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
