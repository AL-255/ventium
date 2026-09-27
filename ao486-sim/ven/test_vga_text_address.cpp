#include "vga_text_address.h"
#include <cassert>
#include <cstdio>
int main() {
    unsigned checks = 0;
    for (unsigned a = 0; a < 65536; ++a) {
        assert(vga_text_address(a, false, true, false, true, true) == a);
        assert(vga_text_address(a, true, false, false, true, true)
               == (a * 4 % 65536 + a / 16384));
        assert(vga_text_address(a, false, false, true, true, true)
               == (a * 2 % 65536 + a / 32768));
        assert(vga_text_address(a, false, false, false, true, true)
               == (a * 2 % 65536 + (a / 8192) % 2));
        for (unsigned scan = 0; scan < 4; ++scan)
            assert(vga_text_address(a, false, true, false, false, false, scan)
                   == ((a & 0x9fff) | scan * 8192));
        checks += 8;
    }
    // Standard mode-3 word addressing: row stride 80 chars -> 160 RAM slots.
    assert(vga_text_address(80, false, false, false, true, true) == 160);
    std::printf("VGA-TEXT-ADDRESS-OK (%u mappings)\n", checks);
}
