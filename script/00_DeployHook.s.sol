// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BaseScript} from "./base/BaseScript.sol";

import {PegHook} from "../src/PegHook.sol";

import "forge-std/Script.sol";

// forge script script/00_DeployHookSepolia.s.sol \
//   --rpc-url arbitrum_sepolia \
//   --private-key 0xYOUR_PRIVATE_KEY \
//   --broadcast

// This code follows https://github.com/uniswapfoundation/v4-template

/// @notice Mines the address and deploys the Peghook.sol Hook contract
contract DeployHookScript is BaseScript {
    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(PegHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        PegHook peghook = new PegHook{salt: salt}(poolManager);
        vm.stopBroadcast();

        require(address(peghook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
