// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#ifndef VENTIUM_BFM_STORE_POLICY_H
#define VENTIUM_BFM_STORE_POLICY_H

// The standalone AXI slave writes MemModel, not the ao486 ROM/UMA backend.
// Describe that backing's byte effects; never change bus strobes or cacheability.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <type_traits>
#include <utility>

namespace ventium {
struct BfmStorePolicy {
    uint32_t address_mask = 0xffffffffu;
    uint32_t ram_top = 0;
    bool option_rom = false;

    uint8_t mask(uint32_t address) const {
        uint8_t result = 0;
        for (unsigned byte = 0; byte < 4; ++byte) {
            const uint32_t a = (address + byte) & address_mask;
            // Match MemModel's RAM-top hole, including the 256-KiB BIOS alias.
            const bool dropped = ram_top && a >= ram_top && a < 0xfffc0000u;
            // MemModel reads these aliases from an immutable option-ROM copy.
            // Conservatively exclude them whenever that optional mode is on;
            // absence of an optional ROM must not create a stale cached update.
            const bool overlaid = option_rom &&
                ((a & 0xffff0000u) == 0xfebe0000u ||
                 (a & 0xfffc0000u) == 0xfeb80000u);
            if (!dropped && !overlaid) result |= uint8_t(1u << byte);
        }
        return result;
    }
};

template<class T, class = void> struct HasStorePolicy : std::false_type {};
template<class T> struct HasStorePolicy<T, std::void_t<
    decltype(std::declval<T>().store_policy_addr),
    decltype(std::declval<T>().store_policy_update_mask)>> : std::true_type {};
template<class T, class = void> struct HasPairStorePolicy : std::false_type {};
template<class T> struct HasPairStorePolicy<T, std::void_t<
    decltype(std::declval<T>().store_pair_policy_addr),
    decltype(std::declval<T>().store_pair_policy_update_mask)>> : std::true_type {};

template<class T> void drive_bfm_store_policy(T* top, const BfmStorePolicy& policy) {
    static_assert(!HasPairStorePolicy<T>::value || HasStorePolicy<T>::value,
                  "paired store-policy ports require the U policy ports");
    if constexpr (HasStorePolicy<T>::value)
        top->store_policy_update_mask = policy.mask(top->store_policy_addr);
    if constexpr (HasPairStorePolicy<T>::value)
        top->store_pair_policy_update_mask = policy.mask(top->store_pair_policy_addr);
}

template<class T> BfmStorePolicy make_bfm_store_policy(uint32_t address_mask) {
    BfmStorePolicy policy;
    policy.address_mask = address_mask;
    if constexpr (HasStorePolicy<T>::value) {
        if (const char* text = std::getenv("VEN_RAM_TOP_MB")) {
            char* end = nullptr;
            const unsigned long mb = std::strtoul(text, &end, 10);
            if (!*text || *end || mb > 4095) {
                std::fprintf(stderr, "tb: invalid VEN_RAM_TOP_MB for store policy\n");
                std::exit(2);
            }
            policy.ram_top = uint32_t(mb) * 0x100000u;
        }
        policy.option_rom = std::getenv("VEN_VGA_OPTROM") != nullptr;
        std::fprintf(stderr,
            "tb: [store-policy] backend=MemModel u=1 v=%u address-mask=%08x ram-top=%08x option-rom=%u\n",
            unsigned(HasPairStorePolicy<T>::value), policy.address_mask,
            policy.ram_top, unsigned(policy.option_rom));
    }
    return policy;
}
}  // namespace ventium
#endif
