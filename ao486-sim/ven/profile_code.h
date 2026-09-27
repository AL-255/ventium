#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdio>

// Snapshot-memory observation only: no page-table A/D updates or DUT evals.
// This is not an instruction-fetch permission check or an ISA oracle.
namespace ven_profile_code {
inline bool byte(const uint8_t* mem, size_t size, uint32_t cr0, uint32_t cr3,
                 uint32_t cr4, uint32_t linear, uint8_t& value) {
    auto word = [&](uint32_t address, uint32_t& result) {
        if (uint64_t(address)+4 > size) return false;
        result = uint32_t(mem[address]) | (uint32_t(mem[address+1])<<8) |
                 (uint32_t(mem[address+2])<<16) | (uint32_t(mem[address+3])<<24);
        return true;
    };
    uint32_t physical = linear;
    if (cr0 & 0x80000000u) {
        uint32_t pde, pte;
        if (cr4 & 0x20u) return false; // no PAE interpretation
        if (!word((cr3 & 0xfffff000u) + (linear>>22)*4, pde) || !(pde&1)) return false;
        if (pde & 0x80) {
            if (!(cr4&0x10) || (pde&0x003fe000u)) return false;
            physical=(pde&0xffc00000u)|(linear&0x003fffffu);
        } else {
            if (!word((pde&0xfffff000u)+((linear>>12)&1023)*4,pte) || !(pte&1)) return false;
            physical=(pte&0xfffff000u)|(linear&4095);
        }
    }
    if (physical >= size) return false;
    value=mem[physical];
    return true;
}
inline void dump(FILE* out, const uint8_t* mem, size_t size, uint32_t base,
                 uint32_t limit, uint32_t cr0, uint32_t cr3, uint32_t cr4,
                 uint32_t start) {
    for (unsigned i=0;i<1024;i++) {
        if (!(i%16)) std::fprintf(out,"[CODE] eip=%08x bytes=",uint32_t(start+i));
        uint8_t value=0;
        if (uint64_t(start)+i<=limit && uint64_t(start)+i<=UINT32_MAX &&
            byte(mem,size,cr0,cr3,cr4,base+start+i,value)) std::fprintf(out,"%02x",value);
        else std::fprintf(out,"??");
        if (i%16==15) std::fprintf(out,"\n");
    }
}
}
