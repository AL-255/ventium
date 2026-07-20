#!/usr/bin/env bash
# apply_win95_display_fix.sh — point the guest Win95 display driver at the standard
# VGA driver that matches the emulated ao486 adapter.
#
# WHY: this Win95 image ships SYSTEM.INI with `[boot] display.drv=pnpdrvr.drv`, the
# Plug-and-Play display stub, which loads the registry's driver (a Cirrus Logic SVGA)
# -- but pnpdrvr.drv is not even installed on the disk and the ao486 emulates plain
# VGA, not Cirrus. GDI then can load no display driver, throws "Your display adapter
# is not configured properly", and first-boot hangs before Explorer launches.
# The fix sets `display.drv=vga.drv` (present on the disk, standard-VGA, 640x480x16 =
# mode 12h, which the ao486 VGA renders pixel-accurately). See AO486_SOC_FIX.md #10.
#
# Requires: mtools (mcopy/mtype/mdir). Edits the image in place; a .system.ini.bak is
# saved next to the image.
#
# Usage: apply_win95_display_fix.sh <path-to-win95.vhd> [partition-byte-offset]
#        default offset = 1048576 (partition 1 at LBA 2048 on a standard MBR image)
set -euo pipefail

IMG="${1:?usage: apply_win95_display_fix.sh <win95.vhd> [offset]}"
OFF="${2:-1048576}"
[ -f "$IMG" ] || { echo "error: image not found: $IMG" >&2; exit 1; }
command -v mcopy >/dev/null || { echo "error: mtools not installed (need mcopy/mtype/mdir)" >&2; exit 1; }

export MTOOLS_SKIP_CHECK=1
MRC="$(mktemp)"; trap 'rm -f "$MRC" "$TMPINI" "$NEWINI"' EXIT
printf 'drive c: file="%s" offset=%s\n' "$(readlink -f "$IMG")" "$OFF" > "$MRC"
export MTOOLSRC="$MRC"

# Sanity: vga.drv (and its dibeng.dll dependency) must exist on the disk.
if ! mdir "c:/windows/system/vga.drv" >/dev/null 2>&1; then
  echo "error: C:\\WINDOWS\\SYSTEM\\VGA.DRV not found on the image -- is this a Win95 FAT16 image at offset $OFF?" >&2
  exit 1
fi

TMPINI="$(mktemp)"; NEWINI="$(mktemp)"
mtype "c:/windows/system.ini" > "$TMPINI" 2>/dev/null || { echo "error: cannot read C:\\WINDOWS\\SYSTEM.INI" >&2; exit 1; }
cp "$TMPINI" "${IMG%.vhd}.system.ini.bak" 2>/dev/null || cp "$TMPINI" "$IMG.system.ini.bak"

cur=$(grep -iE '^\s*display\.drv=' "$TMPINI" | head -1 | tr -d '\r')
echo "current [boot] $cur"
if grep -qiE '^\s*display\.drv=vga\.drv\s*$' "$TMPINI"; then
  echo "already set to vga.drv -- nothing to do."; exit 0
fi
# Rewrite ONLY the [boot] section's display.drv (leave the [boot.description] label
# line "display.drv=Cirrus Logic" untouched). Portable awk (no gawk-only IGNORECASE):
# normalise the section header and compare case-insensitively via tolower().
# Strip CR first (portable across mawk/gawk; mtype preserves DOS CRLF and mcopy -t
# re-adds it on write). Then rewrite ONLY the [boot] section's display.drv, leaving
# the [boot.description] "display.drv=Cirrus Logic" label line alone.
tr -d '\r' < "$TMPINI" | awk '
  /^[ \t]*\[/ { s=$0; gsub(/[ \t]/,"",s); sec=tolower(s) }
  { if (tolower($0) ~ /^[ \t]*display\.drv=/ && sec == "[boot]") sub(/=.*/,"=vga.drv"); print }
' > "$NEWINI"

mcopy -o -t "$NEWINI" "c:/windows/system.ini"
echo -n "new [boot] "; mtype "c:/windows/system.ini" 2>/dev/null | grep -iE '^display\.drv=' | head -1
echo "done. Backup: ${IMG%.vhd}.system.ini.bak"
