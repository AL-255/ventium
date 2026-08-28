#!/bin/sh
# Bounded late-fault capture: ao486d's --trace releases a pre-armed comparator.
# Filter its verbose progress output so a diagnostic run remains safe on the
# board's nearly-full root filesystem.
exec /tmp/ao486/ao486d.forcepio \
    --trace \
    --membase 0x60000000 \
    --bios /tmp/ao486 \
    --hdd /tmp/ao486/qk_td.vhd \
    --secs 900 2>&1 | stdbuf -oL grep -E \
    'board_init|mounting HDD0|x86_init done|BOOT SECTOR LOADED|IDESNAP|TIMEDEMO|969 frames|QUAKE COMPLETION|done: x86_polls|DBG\[final\]|LIVE'
