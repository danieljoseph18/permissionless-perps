// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {YieldOptimizer} from "src/markets/YieldOptimizer.sol";
import {HelperConfig, IHelperConfig} from "../HelperConfig.s.sol";
import {IVault} from "src/markets/interfaces/IVault.sol";
import {OwnableRoles} from "src/auth/OwnableRoles.sol";

contract CreateYieldOptimizers is Script {
    IHelperConfig.NetworkConfig public activeNetworkConfig;
    IHelperConfig.Contracts public helperContracts;

    // Enter market for specific chain
    address market = 0x71D126b69d9C10b997De4586D8463d9288EEFe45;
    // Enter router for specific chain
    address router = 0x9Cb93Dd036d8bb0B0DBCace619347735A8de1765;
    // Enter position manager for specific chain
    address positionManager = 0x28058e373Cdf9A0a1F48eE985Eb1926f1A1f2258;
    // Enter price feed for specific chain
    address priceFeed = 0xDdB03961CeE9aBceB26793f48a4d3f97E080E957;

    // Optimizer Keeper
    address optimizerKeeper = 0x93291B194C2b22CD8071Dbd9d694C6Bbf3f2C0Eb;

    uint256 wethMinDeposit = 0;
    uint256 usdcMinDeposit = 0;

    uint256 internal constant _ROLE_42 = 1 << 42;

    /**
     * Vaults and allocations must be in the same order & the same length.
     */
    IVault[] vaults = [
        IVault(address(0x4A6CAEB100d4A7C26a68Ab337772dbC32D1cf41E)), // BTC
        IVault(address(0xB93B6F941d506d211e4Ff5e89bfFAe834D7BA39d)), // ETH
        IVault(address(0x2Ba38BA6b4c0444b98c45C533aCb06633768FBBf)), // SOL
        IVault(address(0x41DDAd527D4346baD33DFFf8A4Ec12a455a39968)), // XRP
        IVault(address(0xa72e71696562D2e5521e698f6f55Be29ac2a6B14)), // LINK
        IVault(address(0x3A8C930EE801e8CBAf8cBB3f33c5f3f11FCD2d5d)) // SUI
    ];
    uint8[] allocations = [30, 20, 20, 10, 10, 10];

    function run() external {
        HelperConfig helperConfig = new HelperConfig();
        activeNetworkConfig = helperConfig.getActiveNetworkConfig();
        helperContracts = activeNetworkConfig.contracts;

        vm.startBroadcast();

        // Remember to name optimizers with the same name as the market
        YieldOptimizer mainOptimizer =
            new YieldOptimizer("Main Optimizer", "M-OP", helperContracts.weth, helperContracts.usdc, market);

        mainOptimizer.initialize(router, positionManager, priceFeed, 0, 0, 0.001 ether, vaults, allocations);

        OwnableRoles(address(mainOptimizer)).grantRoles(optimizerKeeper, _ROLE_42);

        vm.stopBroadcast();
    }
}
