// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/quake_image.cpp
//
// M7.1 minimal loaders for the producer's initial-image JSON + the golden
// .vtrace's int-0x80 sys_call effects. See quake_image.h for the contract.
//
// The parser understands ONLY the fixed shapes gen_trace.py --syscall-proxy
// emits (hex32 "0x%08x" / hex16 "0x%04x" scalar fields; a "regions" array of
// {"vaddr","hex"} | {"vaddr","len","zero":true}; per-record "sys_call":
// {"nr","ret","writes":[...],"gs_base"?}). It is deliberately not a general JSON
// parser — it scans for the field tokens it needs. This keeps the TB
// dependency-free while staying exact for the producer it is paired with.

#include "quake_image.h"

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

// Parse a hex byte (two lowercase/upper hex chars). Returns 0..255.
inline uint8_t hex_byte(const char* p) {
    auto nib = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    };
    return (uint8_t)((nib(p[0]) << 4) | nib(p[1]));
}

// Find the value of a quoted hex scalar field: "<key>":"0x........". Searches
// from `from` and returns the parsed uint32 (0 if absent). When found, advances
// `*next` past the value (so repeated keys, e.g. region "vaddr", scan forward).
uint32_t scan_hex_field(const std::string& s, const char* key,
                        size_t from = 0, size_t* next = nullptr) {
    std::string pat = std::string("\"") + key + "\":\"0x";
    size_t k = s.find(pat, from);
    if (k == std::string::npos) { if (next) *next = from; return 0; }
    size_t v = k + pat.size();
    uint32_t val = (uint32_t)std::strtoul(s.c_str() + v, nullptr, 16);
    if (next) {
        // advance past the closing quote of this value
        size_t q = s.find('"', v);
        *next = (q == std::string::npos) ? s.size() : q + 1;
    }
    return val;
}

// Parse one int-decimal field: "<key>":<int>. Returns false if absent.
bool scan_int_field(const std::string& s, const char* key, size_t from,
                    long long* out, size_t* next = nullptr) {
    std::string pat = std::string("\"") + key + "\":";
    size_t k = s.find(pat, from);
    if (k == std::string::npos) { if (next) *next = from; return false; }
    size_t v = k + pat.size();
    *out = std::strtoll(s.c_str() + v, nullptr, 10);
    if (next) *next = v;
    return true;
}

}  // namespace

QuakeImage load_quake_image(const std::string& path, MemModel& mem) {
    QuakeImage img;
    std::string s;
    if (!slurp(path, &s)) return img;   // ok=false

    // ---- regs (one "regs":{...} object; each field is a hex32) --------------
    // The keys are unique across the whole file's scalar set except where the
    // region array reuses none of them, so a global scan is safe here.
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

    // ---- segment selectors (hex16) ------------------------------------------
    // Restrict to the "seg":{...} object to avoid matching "seg_base" keys.
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

    // ---- regions ------------------------------------------------------------
    // Walk every {"vaddr":"0x...", ...} object in the "regions" array. For a hex
    // region, write its bytes into bus memory; for a zero region, skip (MemModel
    // reads unmapped pages as 0, so the anon zone stays sparse).
    size_t reg_arr = s.find("\"regions\":[");
    size_t scan = (reg_arr == std::string::npos) ? s.size() : reg_arr;
    long n_hex = 0, n_zero = 0;
    long long total_bytes = 0;
    while (true) {
        size_t after_vaddr = scan;
        size_t vkey = s.find("\"vaddr\":\"0x", scan);
        if (vkey == std::string::npos) break;
        uint32_t vaddr = scan_hex_field(s, "vaddr", scan, &after_vaddr);
        // Is this a hex region or a zero region? Look at the bytes immediately
        // following this object's vaddr up to the next object boundary.
        size_t next_obj = s.find("{\"vaddr\"", after_vaddr);
        size_t bound = (next_obj == std::string::npos) ? s.size() : next_obj;
        size_t hexk = s.find("\"hex\":\"", after_vaddr);
        if (hexk != std::string::npos && hexk < bound) {
            size_t hv = hexk + 7;                 // start of the hex string
            size_t he = s.find('"', hv);          // closing quote
            if (he == std::string::npos) he = bound;
            uint32_t a = vaddr;
            for (size_t p = hv; p + 1 < he; p += 2) {
                mem.write8(a++, hex_byte(s.c_str() + p));
            }
            total_bytes += (long long)(he - hv) / 2;
            ++n_hex;
        } else {
            // zero region: {"vaddr","len","zero":true} — intentionally not filled.
            ++n_zero;
        }
        scan = (next_obj == std::string::npos) ? s.size() : next_obj;
        if (scan >= s.size()) break;
    }

    std::fprintf(stderr,
        "quake-image: loaded %ld hex regions (%lld bytes), %ld zero regions "
        "(sparse); entry=0x%08x esp=0x%08x\n",
        n_hex, total_bytes, n_zero, img.eip, img.esp);
    img.ok = true;
    return img;
}

std::vector<SyscallEffect> load_syscall_replay(const std::string& golden_path) {
    std::vector<SyscallEffect> out;
    std::string s;
    if (!slurp(golden_path, &s)) return out;

    // The golden is one JSON object per line. We need, per int-0x80 record, the
    // sys_call effect AND the pc of the NEXT record (resume_eip). So we keep the
    // previous line's sys_call (if any) and resolve its resume_eip from this
    // line's "pc" when we reach it.
    size_t pos = 0;
    bool   have_pending = false;
    SyscallEffect pending;

    auto finalize = [&](uint32_t next_pc, bool has_next) {
        if (have_pending) {
            pending.resume_eip = next_pc;
            pending.has_resume = has_next;
            out.push_back(std::move(pending));
            have_pending = false;
            pending = SyscallEffect{};
        }
    };

    // skip the header line
    {
        size_t nl = s.find('\n', pos);
        pos = (nl == std::string::npos) ? s.size() : nl + 1;
    }

    while (pos < s.size()) {
        size_t nl = s.find('\n', pos);
        size_t end = (nl == std::string::npos) ? s.size() : nl;
        std::string line = s.substr(pos, end - pos);
        pos = (nl == std::string::npos) ? s.size() : nl + 1;
        if (line.empty()) continue;

        // This record's pc resolves any pending syscall's resume_eip.
        uint32_t pc = scan_hex_field(line, "pc");
        finalize(pc, true);

        // Does THIS record carry a sys_call?
        size_t sck = line.find("\"sys_call\":{");
        if (sck == std::string::npos) continue;

        // n (decimal), and the sys_call sub-object.
        long long nval = 0;
        scan_int_field(line, "n", 0, &nval);
        std::string sc = line.substr(sck);   // from "sys_call" to end of line

        SyscallEffect e;
        e.n   = (uint64_t)nval;
        e.ret = scan_hex_field(sc, "ret");
        // gs_base is optional.
        if (sc.find("\"gs_base\":\"0x") != std::string::npos) {
            e.apply_gs = true;
            e.gs_base  = scan_hex_field(sc, "gs_base");
        }
        // writes: each is {"addr":"0x..","hex":".."} OR
        //                 {"addr":"0x..","len":<int>,"zero":true}
        size_t wscan = sc.find("\"writes\":[");
        if (wscan != std::string::npos) {
            size_t cur = wscan;
            while (true) {
                size_t ak = sc.find("\"addr\":\"0x", cur);
                if (ak == std::string::npos) break;
                size_t after_addr = cur;
                uint32_t addr = scan_hex_field(sc, "addr", cur, &after_addr);
                size_t next_w = sc.find("{\"addr\"", after_addr);
                size_t bound = (next_w == std::string::npos) ? sc.size() : next_w;
                SyscallEffect::Write w;
                w.addr = addr; w.zero = false; w.zlen = 0;
                size_t hk = sc.find("\"hex\":\"", after_addr);
                if (hk != std::string::npos && hk < bound) {
                    size_t hv = hk + 7, he = sc.find('"', hv);
                    if (he == std::string::npos || he > bound) he = bound;
                    for (size_t p = hv; p + 1 < he; p += 2)
                        w.bytes.push_back(hex_byte(sc.c_str() + p));
                } else {
                    long long zl = 0;
                    scan_int_field(sc, "len", after_addr, &zl);
                    w.zero = true; w.zlen = (uint32_t)zl;
                }
                e.writes.push_back(std::move(w));
                cur = (next_w == std::string::npos) ? sc.size() : next_w;
                if (cur >= sc.size()) break;
            }
        }
        pending = std::move(e);
        have_pending = true;
    }
    // The int-0x80 is never the very last record in practice, but be safe.
    finalize(0, false);

    std::fprintf(stderr, "quake-replay: %zu int-0x80 sys_call effects loaded\n",
                 out.size());
    return out;
}

}  // namespace ventium
