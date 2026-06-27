[BITS 16]
[ORG 0x7c00]
start:
    cli
    xor ax,ax
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov sp,0x1000
    ; 16-bit LEA must write only BX, preserving EBX[31:16]
    mov ebx, 0xAABBCCDD
    mov bp, 0x118
    lea bx, [bp-0x18]        ; 8d 5e e8 -> BX=0x100, EBX[31:16] must stay 0xAABB
    mov [0x900], ebx         ; expect 0xAABB0100 ; BUG: 0x00000100
    ; 16-bit LEA into CX
    mov ecx, 0x11223344
    lea cx, [0x55]
    mov [0x904], ecx         ; expect 0x11220055 ; BUG: 0x00000055
    ; control: 32-bit LEA (known-good)
    mov edx, 0x99887766
    lea edx, [0x123]
    mov [0x908], edx         ; expect 0x00000123 (32-bit overwrites)
    mov dword [0x8fc], 0x600DC0DE
.h: hlt
    jmp .h
times 510-($-$$) db 0
dw 0xAA55
