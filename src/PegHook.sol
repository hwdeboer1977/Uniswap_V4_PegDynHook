// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src//libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

// Uniswap V4 hook with dynamic asymmetric fees per swap.
// In _beforeSwap we call _computePegFee(key, params.zeroForOne), and inside _computePegFee we compute:
// toward = _isTowardPeg(zeroForOne, sqrtP, sqrtPeg)
// If toward → lower fee (base − magnitude, clamped to MIN_FEE)
// Else → higher fee (base + magnitude, clamped to MAX_FEE)
// Because toward depends on zeroForOne (swap direction) and where the peg sits vs. current price, the fee differs for buys vs sells exactly the way you want.

    struct PegDebug {
        uint24 baseFee;
        uint24 unclampedFee;
        uint24 clampedFee;
        uint256 price1e18;
        uint256 peg1e18;
        uint256 devBps;
        uint256 pctUnits;
        bool toward;
    }

contract PegHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // --- Config ---
    uint24 public constant BASE_FEE        = 5000;   // 0.50% (pips)
    uint24 public constant MIN_FEE         = 500;    // 0.05%
    uint24 public constant MAX_FEE         = 30000;  // 3.00%
    uint24 public constant SLOPE_PER_1PCT  = 2500;   // +0.25% per 1% deviation
    uint16 public constant DEADZONE_BPS    = 25;     // ±0.25%



    error MustUseDynamicFee();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Permissions must match flags used at deployment
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal pure override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        (uint24 fee, ) = _computePegFee(key, params.zeroForOne);
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    // ---- Public helper for tests/monitoring ----
    function previewFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, PegDebug memory dbg)
    {
        return _computePegFee(key, zeroForOne);
    }

    // ---- Core fee computation (shared) ----
    function _computePegFee(PoolKey calldata key, bool zeroForOne)
        internal
        view
        returns (uint24 fee, PegDebug memory dbg)
    {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, key.toId());

        uint256 price1e18 = _price1e18(sqrtP);
        uint256 peg1e18 = 2e18; // TODO: real oracle

        // deviation in bps (safe, 256-bit)
        uint256 devBps = price1e18 > peg1e18
            ? ( (price1e18 - peg1e18) * 10_000 ) / peg1e18
            : ( (peg1e18 - price1e18) * 10_000 ) / peg1e18;

        uint256 unclamped256;
        uint24 base = BASE_FEE;
        bool toward = _isTowardPeg(zeroForOne, sqrtP, _sqrtFromPrice1e18(peg1e18));

        if (devBps > DEADZONE_BPS) {
            
            uint256 pctUnits = (devBps - DEADZONE_BPS) / 100;
            if (pctUnits > 1_000) pctUnits = 1_000; // cap at 1000% deviation, example
            uint256 magnitude256 = pctUnits * SLOPE_PER_1PCT; // keep in 256 bits

            if (toward) {
                // cheaper toward peg; guard underflow by widening first
                unclamped256 = base > magnitude256 ? uint256(base) - magnitude256 : 0;
                if (unclamped256 < MIN_FEE) unclamped256 = MIN_FEE;
            } else {
                // more expensive away from peg; guard overflow before cast
                unclamped256 = uint256(base) + magnitude256;
                if (unclamped256 > MAX_FEE) unclamped256 = MAX_FEE;
            }
        } else {
            unclamped256 = base;
        }

        fee = uint24(unclamped256); // cast only after clamping to [MIN, MAX]

        dbg = PegDebug({
            baseFee: base,
            unclampedFee: uint24(unclamped256 > type(uint24).max ? type(uint24).max : unclamped256),
            clampedFee: fee,
            price1e18: price1e18,
            peg1e18: peg1e18,
            devBps: devBps,
            pctUnits: (devBps > DEADZONE_BPS) ? (devBps - DEADZONE_BPS) / 100 : 0,
            toward: toward
        });
    }

    // direction helper: zeroForOne => price down (sqrt decreases)
    function _isTowardPeg(bool zeroForOne, uint160 sqrtP, uint160 sqrtPeg) internal pure returns (bool) {
        if (sqrtP == sqrtPeg) return true;
        if (zeroForOne) return sqrtPeg <= sqrtP;  // moving down is toward if peg is below/equal
        return sqrtPeg >= sqrtP;                  // moving up is toward if peg is above/equal
    }

    // sqrtPriceX96 → price (1e18)
    function _price1e18(uint160 s) internal pure returns (uint256) {
        uint256 s256 = uint256(s);
        uint256 priceQ0 = FullMath.mulDiv(s256, s256, 1 << 192); // s^2 / Q192
        return priceQ0 * 1e18; // scale (checked by 0.8)
    }

    // approx inverse: 1e18 price → sqrtPriceX96
    function _sqrtFromPrice1e18(uint256 p1e18) internal pure returns (uint160) {
        uint256 x = (p1e18 << 192) / 1e18;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return uint160(y); 
    }
}