; Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
; SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
;
; PROTECTED-MODE reproduction of the DOS-Quake #GP root: a `pop r/m16` to MEMORY
; immediately after a PM segment-register load (which walks the GDT via S_SEGLD).
; The go32 fault dispatcher (cs=2b, 16-bit PM) does:
;     push sel ; pop ds ; pop word [ds:0x4f6c] ; sub ; shr ...
; and the popped stack word must land at [ds:disp]. Lockstep-vs-QEMU showed the
; RTL pop delivered 0x0000 instead of the popped value, so this exercises the same
; sequence in a 16-bit PM code segment. Real-mode is known-good (popseg.asm).
[BITS 16]
[ORG 0x7c00]
start:
    cli
    xor ax,ax
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov sp,0x7000
    lgdt [gdtr]
    mov eax,cr0
    or  al,1
    mov cr0,eax
    jmp 0x08:pm16            ; far jmp into the 16-bit PM code segment (CS16)

pm16:                        ; still BITS 16 (CS16 is a 16-bit PM segment)
    mov ax,0x10
    mov ss,ax                ; ss base 0
    mov sp,0x6000
    mov ds,ax

    ; --- Test 1: the EXACT worker idiom: push val; push sel; pop ds; pop word [ds:disp] ---
    mov ax,0x3b48
    push ax                  ; stack word to be popped
    mov ax,0x18
    push ax                  ; selector for ds (base 0x30000)
    pop ds                   ; PM seg-load (S_SEGLD) immediately before the pop
    pop word [0x50]          ; pop -> [ds:0x50] = [0x30050], must be 0x3b48
    mov ax,0x18
    mov es,ax
    mov bx,[es:0x50]         ; read what the pop actually wrote
    mov ax,0x10
    mov ds,ax
    mov [0x900],bx           ; [0x900] = test1 (expect 0x3b48; BUG: 0x0000)

    ; --- Test 2: mov ds (S_SEGLD) then pop word [ds:disp] ---
    mov ax,0x55aa
    push ax
    mov ax,0x18
    mov ds,ax                ; PM seg-load via MOV, immediately before the pop
    pop word [0x60]          ; pop -> [ds:0x60] = [0x30060], must be 0x55aa
    mov ax,0x18
    mov es,ax
    mov bx,[es:0x60]
    mov ax,0x10
    mov ds,ax
    mov [0x902],bx           ; [0x902] = test2 (expect 0x55aa)

    ; --- Test 3 (control): pop word [ds:disp] with ds settled (spacer) ---
    mov ax,0x18
    mov ds,ax
    nop
    nop
    mov ax,0x66cc
    push ax
    pop word [0x70]          ; pop -> [ds:0x70] = [0x30070], must be 0x66cc
    mov ax,0x18
    mov es,ax
    mov bx,[es:0x70]
    mov ax,0x10
    mov ds,ax
    mov [0x904],bx           ; [0x904] = test3 (expect 0x66cc)

    mov word [0x8fc],0xC0DE  ; done marker
.h: hlt
    jmp .h

align 8
gdt:
    dq 0                     ; 0x00 null
    dw 0xffff,0x0000
    db 0x00,0x9a,0x00,0x00   ; 0x08: 16-bit code, base 0, limit ffff
    dw 0xffff,0x0000
    db 0x00,0x92,0x00,0x00   ; 0x10: 16-bit data, base 0, limit ffff
    dw 0xffff,0x0000
    db 0x03,0x92,0x00,0x00   ; 0x18: 16-bit data, base 0x030000, limit ffff
gdtr:
    dw gdtr-gdt-1
    dd gdt
times 510-($-$$) db 0
dw 0xaa55
