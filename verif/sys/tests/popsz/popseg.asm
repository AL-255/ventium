; Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
; SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
;
; POP r/m16 to MEMORY, immediately after a segment-register load that changes
; the operand segment (DS != SS). This is the go32/CWSDPMI fault-dispatcher
; idiom that breaks DOS-Quake:
;     push 0x33 ; pop ds ; pop word [ds:0x4f6c] ; sub/shr ...
; The popped stack word must be written to the (just-updated) DS:disp. The
; DOS-Quake #GP traced (lockstep vs QEMU) to this POP storing to the STALE DS
; base, so [DS:disp] kept its old value (0) and the dispatcher read garbage.
[BITS 16]
[ORG 0x7c00]
start:
    cli
    xor ax,ax
    mov es,ax
    mov ax,0x9000
    mov ss,ax
    mov sp,0x200

    ; --- Test 1: pop word [ds:mem] with DS loaded by POP right before (DS!=SS) ---
    mov ax,0x3b48
    push ax                 ; stack word to be popped
    push word 0x1000
    pop ds                  ; ds=0x1000 (base 0x10000) -- changed immediately before
    pop word [0x50]         ; pop -> [ds:0x50] = [0x10050], must be 0x3b48
    mov ax,0x1000
    mov es,ax
    mov bx,[es:0x50]        ; read what the POP actually wrote
    xor ax,ax
    mov ds,ax
    mov [0x900],bx          ; [0x900] = test1 result (expect 0x3b48; BUG: 0x0000)

    ; --- Test 2 (control): pop word [ds:mem], DS settled (mov + spacer) ---
    mov ax,0x2000
    mov ds,ax               ; ds=0x2000 (base 0x20000)
    nop
    nop
    mov ax,0x55aa
    push ax
    pop word [0x60]         ; pop -> [ds:0x60] = [0x20060], must be 0x55aa
    mov ax,0x2000
    mov es,ax
    mov bx,[es:0x60]
    xor ax,ax
    mov ds,ax
    mov [0x902],bx          ; [0x902] = control result (expect 0x55aa)

    ; --- Test 3: pop word [ds:mem] with DS loaded by MOV right before (DS!=SS) ---
    mov ax,0x66cc
    push ax
    mov ax,0x3000
    mov ds,ax               ; ds=0x3000 (base 0x30000) -- changed immediately before
    pop word [0x70]         ; pop -> [ds:0x70] = [0x30070], must be 0x66cc
    mov ax,0x3000
    mov es,ax
    mov bx,[es:0x70]
    xor ax,ax
    mov ds,ax
    mov [0x904],bx          ; [0x904] = test3 result (expect 0x66cc; BUG: 0x0000)

    mov dword [0x8fc],0x600DC0DE   ; done marker
.h: hlt
    jmp .h
times 510-($-$$) db 0
dw 0xaa55
