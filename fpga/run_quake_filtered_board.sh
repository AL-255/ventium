#!/bin/sh
# Keep a long hardware Quake run observable without filling the board rootfs.
# The daemon remains unmodified; only its verbose console output is filtered.
exec /tmp/ao486/ao486d.forcepio \
    --membase 0x60000000 \
    --bios /tmp/ao486 \
    --hdd /tmp/ao486/qk_td.vhd \
    --secs 21600 2>&1 | stdbuf -oL grep -E \
    'board_init|mounting HDD0|x86_init done|BOOT SECTOR LOADED|IDESNAP|TIMEDEMO|969 frames|QUAKE COMPLETION|done: x86_polls|DBG\[final\]|LIVE'
