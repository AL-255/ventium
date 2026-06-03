// verif/tb/memmodel.h
//
// Producer C (Verilator C++ testbench) — flat byte-addressable memory + the
// mem_* bus-functional model that services the RTL core's bus port.
//
// Contract: docs/rtl-interface.md §3 (M0 mem_* port group, single-beat,
// combinational-OK ack) and §4 (image loading). This is the M0 placeholder
// bus; M2 adds fetch width/lines, M5 replaces it with the modeled P5 64-bit
// bus FSM (PLAN.md §2 "System / bus").
#ifndef VENTIUM_MEMMODEL_H
#define VENTIUM_MEMMODEL_H

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace ventium {

// Flat, sparse, byte-addressable RAM. Backed by 4 KiB pages held in a hash map
// so a small test image near a high load address (e.g. 0x08048000) does not
// force a multi-megabyte allocation. All accesses are little-endian (x86).
class MemModel {
public:
    static constexpr uint32_t PAGE_SHIFT = 12;             // 4 KiB pages
    static constexpr uint32_t PAGE_SIZE  = 1u << PAGE_SHIFT;
    static constexpr uint32_t PAGE_MASK  = PAGE_SIZE - 1;

    MemModel() = default;

    // ---- raw byte access (used by image loader + read-data path) ----------
    uint8_t  read8 (uint32_t addr) const;
    void     write8(uint32_t addr, uint8_t val);

    // 32-bit little-endian word access. Misaligned addresses are allowed (the
    // model just reads/writes 4 consecutive bytes); the M0 mem_* port presents
    // word-aligned addresses but we do not assume it.
    uint32_t read32 (uint32_t addr) const;
    void     write32(uint32_t addr, uint32_t val);

    // Load a flat binary blob at `load_addr`. Returns bytes loaded, or -1 on
    // failure (file missing / unreadable). docs/rtl-interface.md §4.
    long load_image(const std::string& path, uint32_t load_addr);

    // ---- the bus-functional model -----------------------------------------
    // Service one bus request. Called by the testbench each clock with the
    // core's current bus outputs; returns (rdata, ack). Single-beat: at M0 we
    // ack every well-formed request immediately (combinational-OK, §3).
    //   req   : mem_req
    //   we    : mem_we (1=write)
    //   addr  : mem_addr (byte address)
    //   wdata : mem_wdata
    //   wstrb : mem_wstrb (per-byte enables, writes only)
    // out:
    //   rdata : value to drive on mem_rdata (valid with ack)
    //   ack   : value to drive on mem_ack
    void service(bool req, bool we, uint32_t addr, uint32_t wdata,
                 uint8_t wstrb, uint32_t* rdata, bool* ack);

    // Diagnostics
    uint64_t reads()  const { return reads_;  }
    uint64_t writes() const { return writes_; }

private:
    struct Page { uint8_t b[PAGE_SIZE] = {0}; };

    Page&       page_for(uint32_t addr);          // create-on-write
    const Page* page_lookup(uint32_t addr) const; // null if unmapped

    std::unordered_map<uint32_t, Page> pages_;     // keyed by page number
    uint64_t reads_  = 0;
    uint64_t writes_ = 0;
};

}  // namespace ventium

#endif  // VENTIUM_MEMMODEL_H
