// Read-only, bounded, losslessly compressed complete retained-model observer.
// Format and scope: docs/STATE_DELTA.md. No simulator-state restoration here.
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>
#include <zlib.h>
#include <fcntl.h>
#include <unistd.h>

class StateDelta {
    struct Field { std::string name, type; uint32_t size; };
    struct Region { const uint8_t* data; size_t size; };
    std::vector<Field> fields;
    std::vector<Region> regions;
    std::vector<uint8_t> previous, current, record;
    gzFile file = nullptr;
    uint64_t first = 0, count = 0, wanted = 0;
    bool started = false;
    static void fail(const char* why) { throw std::runtime_error(why); }
    void write(const void* p, size_t n) {
        const auto* b = static_cast<const uint8_t*>(p);
        while (n) {
            unsigned chunk = unsigned(std::min<size_t>(n, 1u << 20));
            if (gzwrite(file, b, chunk) != int(chunk)) fail("state-delta write failed");
            b += chunk; n -= chunk;
        }
    }
    template<class T> void put(T v) { write(&v, sizeof(v)); }
    template<class T> void append(T v) {
        const auto* p = reinterpret_cast<const uint8_t*>(&v);
        record.insert(record.end(), p, p + sizeof(v));
    }
    void gather() {
        size_t pos = 0;
        for (const auto& region : regions) {
            std::memcpy(current.data() + pos, region.data, region.size);
            pos += region.size;
        }
    }
public:
    ~StateDelta() { if (file) gzclose(file); }
    template<class T> void add(const char* name, const T& value, const char* type) {
        static_assert(std::is_trivially_copyable<T>::value, "must not dump pointers/containers");
        if (started || sizeof(T) > UINT32_MAX) fail("invalid state-delta field");
        fields.push_back({name, type, uint32_t(sizeof(T))});
        const auto* p = reinterpret_cast<const uint8_t*>(&value);
        // Adjacent numeric members can be copied together, but never include
        // padding gaps, cell pointers or scheduler containers between fields.
        if (!regions.empty() && uintptr_t(regions.back().data) + regions.back().size == uintptr_t(p))
            regions.back().size += sizeof(T);
        else regions.push_back({p, sizeof(T)});
    }
    void open(const char* path, uint64_t cycle, uint64_t cycles) {
        if (started || !cycles || cycles > 1000000 || fields.empty()) fail("invalid state-delta capture");
        const uint16_t endian = 1;
        if (*reinterpret_cast<const uint8_t*>(&endian) != 1) fail("state-delta requires little endian host");
        // Exclusive creation: never overwrite a prior trace.
        int fd = ::open(path, O_WRONLY | O_CREAT | O_EXCL, 0666);
        if (fd < 0) fail("state-delta output exists or cannot be created");
        file = gzdopen(fd, "wb1");
        if (!file) { ::close(fd); fail("state-delta gzip open failed"); }
        gzbuffer(file, 1u << 20);
        first = cycle; wanted = cycles; started = true;
        uint64_t total = 0;
        for (const auto& field : fields) total += field.size;
        if (total > UINT32_MAX) fail("state-delta state too large");
        current.resize(total); previous.resize(total);
        write("VENDLT01", 8); put(uint32_t(fields.size())); put(first); put(wanted); put(uint32_t(total));
        for (const auto& field : fields) {
            put(uint32_t(field.name.size())); write(field.name.data(), field.name.size());
            put(uint32_t(field.type.size())); write(field.type.data(), field.type.size()); put(field.size);
        }
        gather(); write(current.data(), current.size()); previous = current;
        fprintf(stderr, "STATE-DELTA start=%llu cycles=%llu fields=%zu bytes=%llu regions=%zu\n",
                (unsigned long long)first, (unsigned long long)wanted, fields.size(),
                (unsigned long long)total, regions.size());
    }
    void sample(uint64_t cycle) {
        if (!file) return;
        if (cycle != first + count + 1) fail("state-delta non-consecutive cycle");
        gather(); record.clear(); append(cycle); append(uint32_t(0));
        uint32_t changes = 0;
        for (size_t pos = 0; pos < current.size(); pos += 16) {
            size_t n = std::min<size_t>(16, current.size() - pos);
            if (!std::memcmp(current.data() + pos, previous.data() + pos, n)) continue;
            uint16_t mask = 0;
            for (size_t i = 0; i < n; ++i)
                if (current[pos+i] != previous[pos+i]) mask |= uint16_t(1u << i);
            append(uint32_t(pos)); append(mask);
            for (size_t i = 0; i < n; ++i) if (mask & (1u << i)) record.push_back(current[pos+i]);
            ++changes;
        }
        std::memcpy(record.data()+8, &changes, 4);
        write(record.data(), record.size()); previous.swap(current);
        if (++count == wanted) {
            write("ENDDLT01", 8); put(count);
            // A full terminal image lets readers independently check reconstruction.
            write(previous.data(), previous.size());
            int rc = gzclose(file); file = nullptr;
            if (rc != Z_OK) fail("state-delta close failed");
            fprintf(stderr, "STATE-DELTA-OK cycles=%llu end=%llu\n",
                    (unsigned long long)count, (unsigned long long)cycle);
        }
    }
    bool complete() const { return started && count == wanted; }
};
