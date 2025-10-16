// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct PegDebug {
    uint24 baseFee;
    uint24 unclampedFee;
    uint24 clampedFee;
    uint256 price1e18;
    uint256 peg1e18;
    uint256 devBps;
    uint256 pctUnits;
    bool toward;
    bool arbZone;
}

library PegFeeMath {
    function compute(
        uint256 price1e18,
        uint256 peg1e18,
        bool toward,
        uint24 BASE_FEE,
        uint24 MIN_FEE,
        uint24 MAX_FEE,
        uint256 DEADZONE_BPS,
        uint256 SLOPE_TOWARD,   // fee-units per +1% when toward peg
        uint256 SLOPE_AWAY,     // fee-units per +1% when away from peg
        uint256 ARB_TRIGGER_BPS // e.g. 5000 (50%)
    ) internal pure returns (uint24 fee, PegDebug memory dbg) {
        uint256 devBps = price1e18 > peg1e18
            ? ((price1e18 - peg1e18) * 10_000) / peg1e18
            : ((peg1e18 - price1e18) * 10_000) / peg1e18;

        uint256 unclamped256;
        bool arbZone = devBps >= ARB_TRIGGER_BPS;

        if (arbZone) {
            unclamped256 = toward ? MIN_FEE : MAX_FEE;
        } else if (devBps > DEADZONE_BPS) {
            uint256 pctUnits = (devBps - DEADZONE_BPS) / 100; // whole % points
            uint256 slope = toward ? SLOPE_TOWARD : SLOPE_AWAY;
            uint256 magnitude256 = pctUnits * slope;

            if (toward) {
                unclamped256 = BASE_FEE > magnitude256 ? uint256(BASE_FEE) - magnitude256 : 0;
                if (unclamped256 < MIN_FEE) unclamped256 = MIN_FEE;
            } else {
                unclamped256 = uint256(BASE_FEE) + magnitude256;
                if (unclamped256 > MAX_FEE) unclamped256 = MAX_FEE;
            }
        } else {
            unclamped256 = BASE_FEE;
        }

        fee = uint24(unclamped256);

        dbg = PegDebug({
            baseFee: BASE_FEE,
            unclampedFee: uint24(unclamped256 > type(uint24).max ? type(uint24).max : unclamped256),
            clampedFee: fee,
            price1e18: price1e18,
            peg1e18: peg1e18,
            devBps: devBps,
            pctUnits: (devBps > DEADZONE_BPS) ? (devBps - DEADZONE_BPS) / 100 : 0,
            toward: toward,
            arbZone: arbZone
        });
    }
}
