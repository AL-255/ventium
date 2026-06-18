#!/usr/bin/env bash
# Rebuild the F4A high-cluster repro disk (sim-only). Stable location (survives /tmp clears).
# fdhi.img: FreeDOS + KLO.COM (low cluster, prints [KLO-RAN]+0x07 sentinel) + 18MB filler
#           + KHI.COM (HIGH cluster ~4500, prints [KHI-RAN]) ; AUTOEXEC runs KLO then KHI.
set -euo pipefail; export MTOOLS_SKIP_CHECK=1
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
FDOS=/home/yukidama/github/ventium/ventium-refs/freedos
# markers
cat > klo.asm <<'A'
org 0x100
 mov si,msg
.l: lodsb
 test al,al
 jz .x
 out 0xE9,al
 jmp .l
.x: mov ax,0x4C00
 int 0x21
msg: db "[KLO-RAN]",13,10,7,0
A
sed 's/KLO-RAN/KHI-RAN/; s/,7,0/,0/' klo.asm > khi.asm
nasm -f bin klo.asm -o KLO.COM
nasm -f bin khi.asm -o KHI.COM
# VBR from FreeDOS boot.asm (the validated recipe)
( cd "$FDOS/ke/SOURCE/ke2045/boot" && nasm -f bin -DISFAT16 -o "$HERE/fdboot16.bin" boot.asm )
[ -f filler.dat ] || dd if=/dev/zero of=filler.dat bs=1M count=18 status=none
printf '@echo off\r\nKLO.COM\r\nKHI.COM\r\n' > AUTOEXEC.BAT
HEADS=16; SPT=63; CYLS=56; TOTAL=$((CYLS*HEADS*SPT)); PSTART=63; PSECTORS=$((TOTAL-PSTART)); OUT=fdhi.img
dd if=/dev/zero of=$OUT bs=512 count=$TOTAL status=none
mformat -i "$OUT@@$((PSTART*512))" -h $HEADS -s $SPT -t $CYLS -H $PSTART -c 8 -r 32 -v FDHI ::
mcopy -i "$OUT@@$((PSTART*512))" "${KERNEL:-$FDOS/kernel.sys}" ::KERNEL.SYS
mcopy -i "$OUT@@$((PSTART*512))" "$FDOS/COMMAND.COM" ::COMMAND.COM
mcopy -i "$OUT@@$((PSTART*512))" KLO.COM ::KLO.COM
mcopy -i "$OUT@@$((PSTART*512))" AUTOEXEC.BAT ::AUTOEXEC.BAT
mcopy -i "$OUT@@$((PSTART*512))" filler.dat ::FILLER.DAT
mcopy -i "$OUT@@$((PSTART*512))" KHI.COM ::KHI.COM
python3 - "$OUT" $PSTART $PSECTORS $HEADS $SPT <<'PY'
import sys,struct
img=bytearray(open(sys.argv[1],'rb').read()); pstart,psectors,heads,spt=map(int,sys.argv[2:6])
def l2c(l):
 c=l//(heads*spt); r=l%(heads*spt); h=r//spt; s=r%spt+1
 return (1023,heads-1,spt) if c>1023 else (c,h,s)
def chsb(c,h,s): return bytes([h&0xff,((c>>2)&0xc0)|(s&0x3f),c&0xff])
bc,bh,bs=l2c(pstart); ec,eh,es=l2c(pstart+psectors-1)
e=bytearray(16); e[0]=0x80; e[1:4]=chsb(bc,bh,bs); e[4]=0x06; e[5:8]=chsb(ec,eh,es)
e[8:12]=struct.pack('<I',pstart); e[12:16]=struct.pack('<I',psectors)
img[446:462]=e; img[462:510]=bytes(48); img[0:440]=open('/usr/lib/syslinux/mbr/mbr.bin','rb').read(); img[510]=0x55; img[511]=0xaa
open(sys.argv[1],'wb').write(img)
PY
python3 - "$OUT" $PSTART "$HERE/fdboot16.bin" <<'PY'
import sys
img=bytearray(open(sys.argv[1],'rb').read()); off=int(sys.argv[2])*512
vbr=bytearray(open(sys.argv[3],'rb').read()); vbr[0x0b:0x3e]=img[off+0x0b:off+0x3e]; vbr[510]=0x55; vbr[511]=0xaa
img[off:off+512]=vbr; open(sys.argv[1],'wb').write(img)
PY
echo "built $HERE/$OUT ($(stat -c%s $OUT) bytes)"
mdir -i "$OUT@@$((PSTART*512))" :: 2>/dev/null | grep -iE 'KLO|KHI|AUTO|KERNEL|FILLER'
