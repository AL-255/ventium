#include "rep_accounting.h"

#include <cassert>

int main() {
    RepAccounting a;
    a.observe(1, false, false, 0, 0, 0);       // ordinary instruction
    a.observe(2, false, false, 0, 0, 0);       // U/V pair
    a.observe(1, true, false, 0x100, 0x100, 0x102); // REP element 1
    a.observe(1, true, false, 0x100, 0x100, 0x102); // REP element 2
    a.observe(1, true, false, 0x102, 0x100, 0x102); // final element
    a.observe(1, true, true, 0x202, 0x200, 0x202); // zero-count REP
    a.observe(1, true, false, 0x300, 0x300, 0x302); // window ends mid-REP
    a.observe(1, true, false, 0x500, 0x400, 0x402); // unknown redirect
    assert(a.legacy == 9);
    assert(a.rep_normalized_known == 5);
    assert(a.rep_callbacks == 6);
    assert(a.rep_elements == 5);
    assert(a.rep_completed == 2);
    assert(a.rep_zero_count == 1);
    assert(a.unresolved == 1);
}
