#pragma once
#include <cstdint>

// Read-only mirror of vga.v memory_address_step_1/2. row_scan is the
// character scanline, not the text row. Standard text modes use zero here.
inline uint16_t vga_text_address(uint16_t address, bool dword, bool byte,
                                 bool bit0, bool bit13, bool bit14,
                                 unsigned row_scan = 0) {
    uint16_t a = dword ? uint16_t((address << 2) | (address >> 14))
               : byte ? address
               : uint16_t((address << 1) | ((address >> (bit0 ? 15 : 13)) & 1));
    if (!bit13) a = uint16_t((a & ~0x2000u) | ((row_scan & 1u) << 13));
    if (!bit14) a = uint16_t((a & ~0x4000u) | ((row_scan & 2u) << 13));
    return a;
}
