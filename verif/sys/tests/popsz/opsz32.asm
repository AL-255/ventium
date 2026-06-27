[BITS 16]
[ORG 0x7c00]
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    ; results area at 0x0600 (ds=0)
    ; T1: 32-bit immediate -> EBX, 32-bit store (aligned 0x600)
    mov ebx, 0x11223344
    mov [0x600], ebx
    ; T2: 32-bit immediate -> EDX, store aligned 0x604
    mov edx, 0x55667788
    mov [0x604], edx
    ; T3: 32-bit load from mem -> EBX, store 0x608
    mov ebx, [0x600]
    mov [0x608], ebx
    ; T4: 32-bit store to MISALIGNED +2 addr (0x60e), then read back to 0x614
    mov ebx, 0xDEADBEEF
    mov [0x60e], ebx
    mov ebx, [0x60e]
    mov [0x614], ebx
    ; T5: 32-bit LSS far-ptr load (offset32 @0x630, seg16 @0x634) -> EBX, store 0x61c
    mov dword [0x630], 0x99AABBCC
    mov word  [0x634], 0x0040
    lss ebx, [0x630]
    mov [0x61c], ebx
    ; T6: 32-bit shl -> EBX, store 0x620
    mov ebx, 1
    shl ebx, 20
    mov [0x620], ebx
    ; sentinel
    mov dword [0x5fc], 0x600DC0DE
.hang:
    hlt
    jmp .hang
times 510-($-$$) db 0
dw 0xAA55
