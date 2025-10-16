// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import { PegFeeMath, PegDebug } from "./libraries/PegFeeMath.sol";
import { console2 } from "forge-std/console2.sol";

contract PegFeeTest is Test {
    using PegFeeMath for uint256;

    // ---- Realistic constants ----
    uint24  constant MIN_FEE = 500;          // 0.05%
    uint24  constant BASE_FEE = 3000;        // 0.30%
    uint24  constant MAX_FEE = 100_000;      // 10.00%
    uint256 constant DEADZONE_BPS = 25;      // 0.25%
    uint256 constant ARB_TRIGGER_BPS = 5_000;// 50%

    // Asymmetric slopes
    uint256 constant SLOPE_TOWARD = 150;     // −0.015% per +1% deviation
    uint256 constant SLOPE_AWAY   = 1200;    // +0.12%  per +1% deviation

    function _compute(uint256 price1e18, uint256 peg1e18, bool toward)
        internal
        pure
        returns (uint24 f, PegDebug memory dbg)
    {
        return PegFeeMath.compute(
            price1e18,
            peg1e18,
            toward,
            BASE_FEE,
            MIN_FEE,
            MAX_FEE,
            DEADZONE_BPS,
            SLOPE_TOWARD,
            SLOPE_AWAY,
            ARB_TRIGGER_BPS
        );
    }

    // --- helpers: minimal devBps to guarantee clamps (asymmetric) ---
    function _devBpsForAwayClamp() internal pure returns (uint256) {
        // pctUnits >= ceil((MAX - BASE) / SLOPE_AWAY)
        uint256 needPct = (uint256(MAX_FEE) - uint256(BASE_FEE) + (SLOPE_AWAY - 1)) / SLOPE_AWAY;
        return needPct * 100 + DEADZONE_BPS + 1;
    }

    function _devBpsForTowardClamp() internal pure returns (uint256) {
        // pctUnits >= ceil((BASE - MIN) / SLOPE_TOWARD)
        uint256 needPct = (uint256(BASE_FEE) - uint256(MIN_FEE) + (SLOPE_TOWARD - 1)) / SLOPE_TOWARD;
        return needPct * 100 + DEADZONE_BPS + 1;
    }

    function _priceAbove(uint256 peg1e18, uint256 devBps) internal pure returns (uint256) {
        return (peg1e18 * (10_000 + devBps)) / 10_000;
    }

    function _priceBelow(uint256 peg1e18, uint256 devBps) internal pure returns (uint256) {
        if (devBps >= 10_000) devBps = 9_999; // keep positive
        return (peg1e18 * (10_000 - devBps)) / 10_000;
    }

    // ---- Baselines ----
    function test_DeadzoneKeepsBase_equal() public {
        (uint24 f,) = _compute(1e18, 1e18, true);
        assertEq(f, BASE_FEE);
    }

    function test_DeadzoneKeepsBase_smallDiffBelowDZ() public {
        (uint24 f,) = _compute(10020e14 /*1.0020*/, 1e18, false);
        assertEq(f, BASE_FEE);
    }

    // ---- Shape checks ----
    function test_TowardCheaper_AwayMoreExpensive_sameDeviation() public {
        uint256 price = 105e16; // 1.05
        uint256 peg = 1e18;
        (uint24 ftow,) = _compute(price, peg, true);
        (uint24 fawy,) = _compute(price, peg, false);
        assertLe(ftow, BASE_FEE);
        assertGe(fawy, BASE_FEE);
        assertLe(ftow, fawy);
    }

    // ---- Clamps (with asymmetric slopes) ----
    function test_ClampsAtMin_whenFarToward() public {
        uint256 peg  = 1e18;
        uint256 dev  = _devBpsForTowardClamp(); // ~5% + deadzone with these params
        console2.log("Deviation for clamp MIN:", dev);
        uint256 price = _priceAbove(peg, dev);  // any side ok for pure kernel; toward=true drives down

        (uint24 f, PegDebug memory dbg) = _compute(price, peg, /*toward=*/true);
        //console2.log("toward:", dbg.toward, "arbZone:", dbg.arbZone, "fee:", f);
        console2.log("toward:", dbg.toward, "arbZone:", dbg.arbZone);
        console2.log("fee:", f);
        assertEq(f, MIN_FEE);
    }

    function test_ClampsAtMax_whenFarAway() public {
        uint256 peg  = 1e18;
        uint256 dev  = _devBpsForAwayClamp();   // ~81%+ with SLOPE_AWAY=1200 & MAX=10%
        console2.log("Deviation for clamp MAX:", dev);
        uint256 price = _priceAbove(peg, dev);

        (uint24 f, PegDebug memory dbg) = _compute(price, peg, /*toward=*/false);
        console2.log("toward:", dbg.toward, "arbZone:", dbg.arbZone);
        console2.log("fee:", f);
        assertEq(f, MAX_FEE);
    }

    // ---- Arb zone behavior (>= 50%) ----
    function test_ArbZoneSetsExtremes() public {
        uint256 peg = 1e18;
        uint256 dev = 6000; // 60% > 50% trigger

        // below-peg price, toward buy should be MIN; above-peg away should be MAX
        uint256 priceBelow = _priceBelow(peg, dev);
        (uint24 fTow, PegDebug memory dbgTow) = _compute(priceBelow, peg, true);
        assertTrue(dbgTow.arbZone);
        assertEq(fTow, MIN_FEE);

        uint256 priceAbove = _priceAbove(peg, dev);
        (uint24 fAway, PegDebug memory dbgAway) = _compute(priceAbove, peg, false);
        assertTrue(dbgAway.arbZone);
        assertEq(fAway, MAX_FEE);
    }

    // ---- Fuzz guards ----
    function testFuzz_Bounds(uint256 price, uint256 peg) public {
        vm.assume(price > 0 && peg > 0 && price < 1e27 && peg < 1e27);
        (uint24 ftow,) = _compute(price, peg, true);
        (uint24 fawy,) = _compute(price, peg, false);
        assertTrue(ftow >= MIN_FEE && ftow <= MAX_FEE);
        assertTrue(fawy >= MIN_FEE && fawy <= MAX_FEE);
    }
}
