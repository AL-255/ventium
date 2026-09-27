// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
#include <cstdio>
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
    // Service one bus request. Called by the testbench while it settles the
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
    // `clock_tick` is true exactly once, immediately before each rising edge.
    // It is irrelevant at zero configured latency.  With a latency enabled it
    // is the only call allowed to start/progress a delayed transaction: the TB
    // calls service several times per clock for combinational settling, which
    // must never turn one programmed core-cycle delay into several decrements.
    void service(bool req, bool we, uint32_t addr, uint32_t wdata,
                 uint8_t wstrb, bool clock_tick, uint32_t* rdata, bool* ack);

    // Called just after the rising-edge evaluation that consumed a delayed
    // response.  It removes the pulse before the next combinational settle so
    // an old acknowledgement cannot be observed by a newly selected request.
    void finish_clock_tick() { lat_resp_valid_ = false; }

    // ---- task #52: OPTIONAL access latency ---------------------------------
    // The model above acks in the SAME cycle, always. That makes the cycle gate's
    // M4/M5 bands a statement about the core's fill FSM, NOT about memory cost --
    // which is how a machine retiring nothing on 98.66% of hardware cycles
    // (DISK_BOOT_STATUS UPDATE 229/230) stayed green through every gate.
    //
    // set_latency() adds a per-request stall: `ack` is withheld for N cycles
    // before completing. DEFAULT IS 0 => byte-identical to the previous model, so
    // every existing golden stays reproducible and enabling this is an explicit,
    // auditable act. Reads and writes are separate because the real path is
    // asymmetric: a read waits for data to come back, whereas a write's cost
    // depends on whether the backing posts it or blocks for the B response
    // (ventium_l1_axi.sv:226-231 documents the backing as SINGLE-OUTSTANDING).
    //
    // CALIBRATE THESE FROM HARDWARE (perf counters at 0x100-0x150), do not guess.
    void set_latency(unsigned read_cycles, unsigned write_cycles) {
        rd_lat_ = read_cycles; wr_lat_ = write_cycles;
        lat_pending_ = false; lat_wait_ = 0;
        lat_resp_valid_ = false; lat_resp_data_ = 0;
        lat_protocol_error_ = false;
    }
    // Optional bus-visible physical-address filter for a targeted delay probe.
    // If present, only accesses satisfying `(addr & mask) == (match & mask)`
    // receive their configured read/write latency; all others retain their
    // normal combinational response.  This lets a data-path regression avoid
    // accidentally testing a separately modeled instruction-fill interface.
    void set_latency_match(uint32_t match, uint32_t mask) {
        lat_match_en_ = true; lat_match_ = match; lat_match_mask_ = mask;
    }
    unsigned read_latency()  const { return rd_lat_; }
    unsigned write_latency() const { return wr_lat_; }
    bool latency_protocol_error() const { return lat_protocol_error_; }

    // ---- checkpoint snapshot / restore (M14 periodic-state replay) ---------
    // Dump/load every mapped page (page number + 4 KiB) to/from an open binary
    // file. Sparse: only touched pages are written, so the size tracks the
    // working set, not the address space. snapshot() is const; restore() clears
    // existing pages first so the model exactly matches the saved state.
    void snapshot(FILE* f) const;
    void restore(FILE* f);

    // Diagnostics
    uint64_t reads()  const { return reads_;  }
    uint64_t writes() const { return writes_; }

private:
    // task #52 latency state. A delayed request is captured at one explicit
    // core-clock boundary, then must remain stable until its response.  The
    // default no-latency path never touches these fields, preserving its old
    // combinational semantics (including its repeated settle calls).
    unsigned rd_lat_ = 0, wr_lat_ = 0;
    bool     lat_match_en_ = false;
    uint32_t lat_match_ = 0, lat_match_mask_ = 0;
    bool     lat_pending_ = false;
    bool     lat_we_ = false;
    uint32_t lat_addr_ = 0, lat_wdata_ = 0;
    uint8_t  lat_wstrb_ = 0;
    unsigned lat_wait_ = 0;
    bool     lat_resp_valid_ = false;
    uint32_t lat_resp_data_ = 0;
    bool     lat_protocol_error_ = false;

    struct Page { uint8_t b[PAGE_SIZE] = {0}; };

    Page&       page_for(uint32_t addr);          // create-on-write
    const Page* page_lookup(uint32_t addr) const; // null if unmapped

    std::unordered_map<uint32_t, Page> pages_;     // keyed by page number

    // 1-entry page cache: instruction fetch + data access are highly local, so
    // caching the last looked-up page skips the hash-map find() on the hot path
    // (read32 was doing 4 finds/word). unordered_map nodes are address-stable
    // across insertions, so a cached Page* stays valid (we never erase except in
    // restore(), which invalidates it); page_for refreshes it on absent->present.
    // mutable: used from the const read path.
    mutable uint32_t    cache_pidx_  = ~0u;
    mutable const Page* cache_page_  = nullptr;
    mutable bool        cache_valid_ = false;

    uint64_t reads_  = 0;
    uint64_t writes_ = 0;
};

}  // namespace ventium

#endif  // VENTIUM_MEMMODEL_H
