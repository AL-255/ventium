// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/win95_cosim.cpp
//
// M7.3b minimal loaders for the Win95 producer's initial physical-memory image
// JSON + the golden .vtrace's dev_in[] read values. See win95_cosim.h.
//
// Parses ONLY the fixed shapes gen_trace.py --system-replay emits: hex32/hex16
// scalar regs/segs; a "regions" array of {"paddr":"0x..","hex":".."}; per-record
// "dev_in":[{"addr":<int>,"val":<int>,"size":<int>,"region":"<str>"}]. Not a
// general JSON parser — it scans for the field tokens it needs (dependency-free,
// O(1)-ish per line), exactly like quake_image.cpp.

#include "win95_cosim.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace ventium {

namespace {

// Read an entire file into a std::string. Returns false on failure.
bool slurp(const std::string& path, std::string* out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz < 0) { std::fclose(f); return false; }
    out->resize((size_t)sz);
    size_t got = std::fread(&(*out)[0], 1, (size_t)sz, f);
    std::fclose(f);
    out->resize(got);
    return true;
}

inline uint8_t hex_byte(const char* p) {
    auto nib = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    };
    return (uint8_t)((nib(p[0]) << 4) | nib(p[1]));
}

// "<key>":"0x........"  -> parsed uint32 (0 if absent). Advances *next past the
// value's closing quote so repeated keys (e.g. region "paddr") scan forward.
uint32_t scan_hex_field(const std::string& s, const char* key,
                        size_t from = 0, size_t* next = nullptr) {
    std::string pat = std::string("\"") + key + "\":\"0x";
    size_t k = s.find(pat, from);
    if (k == std::string::npos) { if (next) *next = from; return 0; }
    size_t v = k + pat.size();
    uint32_t val = (uint32_t)std::strtoul(s.c_str() + v, nullptr, 16);
    if (next) {
        size_t q = s.find('"', v);
        *next = (q == std::string::npos) ? s.size() : q + 1;
    }
    return val;
}

// "<key>":<int>  -> parsed (un)signed 64-bit. Returns false if absent. The win95
// dev_in fields are decimal ints; one val is 0xFFFFFFFFFFFFFFFF (the -1 IN), so
// parse as unsigned 64-bit (strtoull wraps a leading minus, but the producer
// emits the unsigned form, so strtoull is exact).
bool scan_u64_field(const std::string& s, const char* key, size_t from,
                    uint64_t* out, size_t* next = nullptr) {
    std::string pat = std::string("\"") + key + "\":";
    size_t k = s.find(pat, from);
    if (k == std::string::npos) { if (next) *next = from; return false; }
    size_t v = k + pat.size();
    *out = std::strtoull(s.c_str() + v, nullptr, 10);
    if (next) *next = v;
    return true;
}

}  // namespace

Win95Image load_win95_image(const std::string& path, MemModel& mem) {
    Win95Image img;
    std::string s;
    if (!slurp(path, &s)) return img;   // ok=false

    // ---- regs (one "regs":{...} object; each field a hex32) — cross-check only.
    img.eip    = scan_hex_field(s, "eip");
    img.esp    = scan_hex_field(s, "esp");
    img.eflags = scan_hex_field(s, "eflags");
    img.eax    = scan_hex_field(s, "eax");
    img.ecx    = scan_hex_field(s, "ecx");
    img.edx    = scan_hex_field(s, "edx");
    img.ebx    = scan_hex_field(s, "ebx");
    img.ebp    = scan_hex_field(s, "ebp");
    img.esi    = scan_hex_field(s, "esi");
    img.edi    = scan_hex_field(s, "edi");

    // ---- segment selectors (hex16), restricted to the "seg":{...} object.
    {
        size_t seg = s.find("\"seg\":{");
        size_t segend = (seg == std::string::npos) ? std::string::npos
                                                   : s.find('}', seg);
        if (seg != std::string::npos && segend != std::string::npos) {
            std::string sub = s.substr(seg, segend - seg);
            img.cs = (uint16_t)scan_hex_field(sub, "cs");
            img.ss = (uint16_t)scan_hex_field(sub, "ss");
            img.ds = (uint16_t)scan_hex_field(sub, "ds");
            img.es = (uint16_t)scan_hex_field(sub, "es");
            img.fs = (uint16_t)scan_hex_field(sub, "fs");
            img.gs = (uint16_t)scan_hex_field(sub, "gs");
        }
    }

    // ---- regions: walk every {"paddr":"0x..","hex":".."} object and write its
    // bytes into bus memory at the PHYSICAL address (paging is off at boot; the
    // RTL's mem bus addresses these directly).
    size_t reg_arr = s.find("\"regions\":[");
    size_t scan = (reg_arr == std::string::npos) ? s.size() : reg_arr;
    while (true) {
        size_t pkey = s.find("\"paddr\":\"0x", scan);
        if (pkey == std::string::npos) break;
        size_t after_paddr = scan;
        uint32_t paddr = scan_hex_field(s, "paddr", scan, &after_paddr);
        size_t next_obj = s.find("{\"paddr\"", after_paddr);
        size_t bound = (next_obj == std::string::npos) ? s.size() : next_obj;
        size_t hexk = s.find("\"hex\":\"", after_paddr);
        if (hexk != std::string::npos && hexk < bound) {
            size_t hv = hexk + 7;                 // start of the hex string
            size_t he = s.find('"', hv);          // closing quote
            if (he == std::string::npos) he = bound;
            uint32_t a = paddr;
            for (size_t p = hv; p + 1 < he; p += 2)
                mem.write8(a++, hex_byte(s.c_str() + p));
            img.total_bytes += (long long)(he - hv) / 2;
            ++img.n_regions;
        }
        scan = (next_obj == std::string::npos) ? s.size() : next_obj;
        if (scan >= s.size()) break;
    }

    // NOTE on the top-of-4GB BIOS ROM: the qemu `pc` machine maps the immutable
    // 256 KiB system-BIOS ROM at 0xFFFC0000..0xFFFFFFFF (the low 0xC0000..0xFFFFF
    // window is a SEPARATE PAM shadow RAM that starts zero and the BIOS fills via
    // `rep movsb` from the high ROM). The producer now captures that high ROM region
    // DIRECTLY (gen_trace _INIT_MEM_REGIONS 0xFFFC0000,0x40000), so it is loaded at
    // its real paddr by the regions loop above — no software mirror is needed (and a
    // mirror would be WRONG, since the low 0xC0000..0xEFFFF window is zero at reset).
    // The RTL fetches/reads the high alias directly from these captured ROM bytes.

    std::fprintf(stderr,
        "win95-image: loaded %ld phys regions (%lld bytes); reset cs:eip=0x%04x:0x%08x "
        "edx=0x%08x (cross-check)\n",
        img.n_regions, img.total_bytes, img.cs, img.eip, img.edx);
    img.ok = true;
    return img;
}

std::vector<DevIn> load_devin_replay(const std::string& golden_path,
                                     bool* had_intr) {
    std::vector<DevIn> out;
    if (had_intr) *had_intr = false;
    std::string s;
    if (!slurp(golden_path, &s)) return out;

    size_t pos = 0;
    // skip the header line
    {
        size_t nl = s.find('\n', pos);
        pos = (nl == std::string::npos) ? s.size() : nl + 1;
    }

    long n_records_with_devin = 0;
    while (pos < s.size()) {
        size_t nl = s.find('\n', pos);
        size_t end = (nl == std::string::npos) ? s.size() : nl;
        // Work on a view of just this line via offsets into `s`.
        std::string line = s.substr(pos, end - pos);
        pos = (nl == std::string::npos) ? s.size() : nl + 1;
        if (line.empty()) continue;

        // An `intr` field would mean a delivered interrupt in the prefix — the
        // M7.3a contract says there are 0 in the bounded prefix (intr injection is
        // deferrable). Flag it so the caller can report honestly (never fake it).
        if (had_intr && line.find("\"intr\":") != std::string::npos)
            *had_intr = true;

        // dev_in:[ {addr,val,size,region}, ... ] — present only on IN/MMIO-read
        // records. Flatten each entry to a DevIn, in array order.
        size_t dk = line.find("\"dev_in\":[");
        if (dk == std::string::npos) continue;

        // record n (decimal).
        uint64_t nval = 0;
        scan_u64_field(line, "n", 0, &nval);

        // Bound the scan to the dev_in array (up to its closing ']'). Each entry
        // has addr/val/size in order; we read them per-entry by walking "addr".
        size_t arr_end = line.find(']', dk);
        if (arr_end == std::string::npos) arr_end = line.size();
        std::string arr = line.substr(dk, arr_end - dk);

        size_t cur = 0;
        while (true) {
            size_t ak = arr.find("\"addr\":", cur);
            if (ak == std::string::npos) break;
            DevIn d;
            d.n = nval;
            uint64_t a = 0, v = 0, sz = 1;
            size_t after = cur;
            scan_u64_field(arr, "addr", ak, &a, &after);
            scan_u64_field(arr, "val",  after, &v, &after);
            scan_u64_field(arr, "size", after, &sz, &after);
            d.port = (uint32_t)a;
            d.val  = v;
            d.size = (uint32_t)sz;
            // region string (optional, for diagnostics).
            size_t rk = arr.find("\"region\":\"", after);
            if (rk != std::string::npos && rk < arr.size()) {
                size_t rv = rk + 10, re = arr.find('"', rv);
                if (re != std::string::npos) d.region = arr.substr(rv, re - rv);
            }
            out.push_back(std::move(d));
            cur = after;
        }
        ++n_records_with_devin;
    }

    std::fprintf(stderr,
        "win95-replay: %zu dev_in read values loaded from %ld records%s\n",
        out.size(), n_records_with_devin,
        (had_intr && *had_intr) ? " (WARNING: intr present in prefix!)" : "");
    return out;
}

}  // namespace ventium
