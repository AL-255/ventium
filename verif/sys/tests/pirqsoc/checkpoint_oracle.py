# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Authoritative end-state CHECKPOINT oracle: run pirqsoc at FULL SPEED under the
# gdbstub (continue, not single-step), with a breakpoint at the deterministic
# post-readback point (just before isa-debug-exit). IRQs DO deliver at full speed,
# so the program reaches N and the readbacks. We then read the deterministic
# architectural checkpoint (GPRs + the var memory). This is the oracle the RTL
# end-state checkpoint is differenced against.
import socket, subprocess, sys, time
QSYS="/home/yukidama/github/ventium/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
IMG="/home/yukidama/github/ventium/verif/sys/tests/pirqsoc/pirqsoc.bin"
PORT=int(sys.argv[1])
BP=int(sys.argv[2],16)   # checkpoint EIP (a HW breakpoint)
def chk(p): return b"$"+p+b"#"+("%02x"%(sum(p)&0xff)).encode()
class RSP:
    def __init__(s,port):
        s.s=socket.create_connection(("127.0.0.1",port),timeout=15); s.s.settimeout(30); s.buf=b""
    def cmd(s,p):
        s.s.sendall(chk(p))
        while True:
            while s.buf[:1] in (b"+",b"-"): s.buf=s.buf[1:]
            i=s.buf.find(b"#")
            if s.buf[:1]==b"$" and i>=0 and len(s.buf)>=i+3:
                pkt=s.buf[1:i]; s.buf=s.buf[i+3:]; s.s.sendall(b"+")
                out=bytearray(); esc=False
                for b in pkt:
                    if esc: out.append(b^0x20); esc=False
                    elif b==0x7d: esc=True
                    else: out.append(b)
                return bytes(out)
            d=s.s.recv(8192)
            if not d: return b"__CLOSED__"
            s.buf+=d
proc=subprocess.Popen([QSYS,"-display","none","-S","-gdb","tcp::%d"%PORT,"-machine","pc","-m","32","-device","isa-debug-exit,iobase=0xf4,iosize=0x04","-bios",IMG],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(1.2)
try:
    r=RSP(PORT); r.cmd(b"qSupported")
    # set a hardware breakpoint at the checkpoint EIP (Z1 = HW bp)
    print("setbp:", r.cmd(b"Z1,%x,1"%BP).decode())
    rep=r.cmd(b"c")  # CONTINUE at full speed -> IRQs deliver, run to the bp
    print("stop-reply:", rep.decode(errors="replace")[:40])
    g=r.cmd(b"g").decode()
    def gp(idx): return int.from_bytes(bytes.fromhex(g[idx*8:idx*8+8]),"little")
    names=["eax","ecx","edx","ebx","esp","ebp","esi","edi","eip"]
    print("--- CHECKPOINT GPRs at EIP=0x%08x ---"%BP)
    for i,n in enumerate(names): print("  %s = 0x%08x"%(n,gp(i)))
    def memw(a):
        m=r.cmd(b"m%x,4"%a); return int.from_bytes(bytes.fromhex(m.decode()),"little")
    print("--- CHECKPOINT mem ---")
    print("  IRQ0_CTR @0x2000 = %d"%memw(0x2000))
    print("  ISR_READ @0x2004 = 0x%02x"%(memw(0x2004)&0xff))
    print("  IMR_READ @0x2008 = 0x%02x"%(memw(0x2008)&0xff))
finally:
    proc.terminate()
    try: proc.wait(timeout=5)
    except: proc.kill()
