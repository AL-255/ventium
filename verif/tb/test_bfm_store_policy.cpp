#include "bfm_store_policy.h"
#include <cassert>

struct NoPorts {};
struct UPorts { uint32_t store_policy_addr=0; uint8_t store_policy_update_mask=0; };
struct UVPorts : UPorts {
    uint32_t store_pair_policy_addr=0;
    uint8_t store_pair_policy_update_mask=0;
};

int main() {
    ventium::BfmStorePolicy policy;
    NoPorts none; UPorts u; UVPorts uv;
    ventium::drive_bfm_store_policy(&none,policy);
    u.store_policy_addr=0x407ffffdu;
    ventium::drive_bfm_store_policy(&u,policy);
    assert(u.store_policy_update_mask==15);
    assert(policy.mask(0xffffffffu)==15); // defined 32-bit address wrap
    assert(policy.mask(0xc0000u)==15);    // flat MemModel RAM, not ao486 ROM
    policy.ram_top=16*1024*1024;
    uv.store_policy_addr=policy.ram_top-2;
    uv.store_pair_policy_addr=policy.ram_top+16;
    ventium::drive_bfm_store_policy(&uv,policy);
    assert(uv.store_policy_update_mask==3 && uv.store_pair_policy_update_mask==0);
    assert(policy.mask(0xfffbfffeu)==12);
    assert(policy.mask(0xfffc0000u)==15);
    policy.ram_top=0;policy.option_rom=true;
    assert(policy.mask(0xfeb7fffeu)==3 && policy.mask(0xfebbfffeu)==12);
    assert(policy.mask(0xfebdfffeu)==3 && policy.mask(0xfebefffeu)==12);
    assert(policy.mask(0xfeb80000u)==0 && policy.mask(0xfebe0000u)==0);
    policy.address_mask=0x0fffffffu;
    assert(policy.mask(0xfebe0000u)==15); // folded RAM, not the high ROM alias
    policy.ram_top=16*1024*1024;
    assert(policy.mask(0x0ffffffeu)==12); // fold is per byte, not base only
    uv.store_policy_addr=0x10001000;uv.store_pair_policy_addr=0x10fffffe;
    ventium::drive_bfm_store_policy(&uv,policy);
    assert(uv.store_policy_update_mask==15 && uv.store_pair_policy_update_mask==3);
    std::puts("BFM-STORE-POLICY-OK");
}
