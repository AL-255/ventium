#include "profile_code.h"
#include <array>
#include <cassert>
int main() {
    std::array<uint8_t,16384> m{};
    auto put=[&](unsigned a,uint32_t v) { for(unsigned i=0;i<4;i++)m[a+i]=v>>(8*i); };
    uint8_t v=0;
    m[0x3010]=0xa5;
    assert(ven_profile_code::byte(m.data(),m.size(),0,0,0,0x3010,v)&&v==0xa5);
    assert(!ven_profile_code::byte(m.data(),m.size(),0,0,0,0x4000,v));
    put(0x1000,0x2003); put(0x2000,0x3003);
    const auto original=m;
    assert(ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0,0x10,v)&&v==0xa5);
    assert(m==original); // observation must not set A/D bits
    assert(!ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0,0x1010,v));
    assert(!ven_profile_code::byte(m.data(),m.size(),0x80000000,0x4000,0,0,v));
    assert(!ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0x20,0,v));
    put(0x1000,0x83);
    assert(!ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0,0x3010,v));
    assert(ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0x10,0x3010,v)&&v==0xa5);
    put(0x1000,0x2083);
    assert(!ven_profile_code::byte(m.data(),m.size(),0x80000000,0x1000,0x10,0,v));
    std::puts("PROFILE-CODE-UNIT-OK");
}
