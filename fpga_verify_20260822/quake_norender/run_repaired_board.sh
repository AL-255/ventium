#!/bin/sh
set -eu

LOG=/tmp/ao486/quake_norender_repaired.log

/tmp/ao486/ao486d \
    --membase 0x60000000 \
    --bios /tmp/ao486 \
    --hdd /tmp/ao486/qk_td.vhd \
    --secs 7200 \
    --text 2>&1 | \
    stdbuf -oL grep -E \
        'board_init|mounting HDD0|x86_init done|IDENTIFY STORE OK|BOOT SECTOR LOADED|IDESNAP|TIMEDEMO|969 frames|FLUSHWD|done: x86_polls|DBG\[final\]' \
        > "$LOG"
