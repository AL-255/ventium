// Exercise the actual PS stdio shim. No RTL, guest or benchmark-specific hook.
#include "file_io.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int cases = 0, stale = 0, errors = 0, close_errors = 0;
    const int lengths[] = {1, 511, 512, 513, 4096, 8192};
    for (int length : lengths) {
        for (int offset : {0, 512, 1025}) {
            const std::string path = std::string(argv[1]) + "/write_" + std::to_string(cases++);
            const int reader = open(path.c_str(), O_RDWR | O_CREAT | O_EXCL, 0600);
            if (reader < 0 || ftruncate(reader, 16384)) return 2;
            fileTYPE file;
            if (!FileOpenEx(&file, path.c_str(), O_RDWR)) return 2;
            std::array<char, 65536> stdio_buffer{};
            if (setvbuf(file.filp, stdio_buffer.data(), _IOFBF, stdio_buffer.size())) return 2;
            std::array<unsigned char, 8192> written{}, seen{};
            for (int i = 0; i < length; ++i) written[i] = (i * 17 + 91) % 251 + 1;
            if (!FileSeek(&file, offset, SEEK_SET)) return 2;
            const int count = length == 512 ? 512 * FileWriteSec(&file, written.data())
                                           : FileWriteAdv(&file, written.data(), length);
            if (count != length || pread(reader, seen.data(), length, offset) != length) return 2;
            if (!std::equal(written.begin(), written.begin() + length, seen.begin())) ++stale;
            // The observer uses a separate descriptor before the writer closes.
            FileClose(&file);
            if (pread(reader, seen.data(), length, offset) != length ||
                !std::equal(written.begin(), written.begin() + length, seen.begin())) ++close_errors;
            unsigned char untouched = 1;
            if (pread(reader, &untouched, 1, offset + length) != 1 || untouched) ++close_errors;
            close(reader);
        }
    }
    for (int sector : {0, 1}) {
        fileTYPE file;
        file.filp = fopen("/dev/full", "wb");
        if (!file.filp) return 2;
        std::array<char, 65536> stdio_buffer{};
        std::array<unsigned char, 512> data{};
        if (setvbuf(file.filp, stdio_buffer.data(), _IOFBF, stdio_buffer.size())) return 2;
        const int count = sector ? FileWriteSec(&file, data.data())
                                 : FileWriteAdv(&file, data.data(), data.size(), -1);
        if (count > 0) ++errors;
        FileClose(&file);
    }
    std::printf("WRITE-VISIBILITY cases=%d stale=%d post_close_errors=%d falsely_successful_errors=%d\n",
                cases, stale, close_errors, errors);
    return stale || close_errors || errors ? 1 : 0;
}
